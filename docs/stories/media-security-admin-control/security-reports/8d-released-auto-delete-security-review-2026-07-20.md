# Security Review — media-security-admin-control / 8d-released-auto-delete

**Reviewer:** Kassandra (nebu-agent-kassandra, adversarial security review)
**Diff scope:** `git diff --staged` — new Oban cron worker
`Nebu.Workers.MediaReleasedAutoDeleteWorker` (`server/lib/nebu/workers/media_released_auto_delete_worker.ex`),
its unit + integration test files, `+ media_released_auto_deleted` in
`Nebu.Compliance.AuditWriter.@known_actions`, and a 3rd Oban cron tuple in
`server/config/config.exs`.
**Date:** 2026-07-20
**Verdict:** **APPROVED — CLEAN** (0 CRITICAL, 0 HIGH, 0 MEDIUM; 2 LOW advisories)

---

## Method

This story is flagged as the largest-blast-radius worker in the epic: it can transition
currently-visible, never-flagged, good `:released` files into `:deleted`. Every claim in
the dev/code-review summaries was re-derived against live source, not trusted:

- Read `Nebu.Media.Config` (`server/lib/nebu/media/config.ex`) end-to-end — the coercion
  (`coerce_value/2`), validation (`validate_value/2`), default map, and encode/decode
  round-trip for `released_delete_after_days`.
- Read `Nebu.Media.StateMachine.transition/4` (`server/lib/nebu/media/state_machine.ex`)
  — its exact success/error return contract and which SQL it runs for `:deleted` vs
  `:hard_deleted`.
- Read `Nebu.Compliance.AuditWriter.log/…` — the unknown-action gate and confirmed the
  new allowlist entry.
- Confirmed `media_state_transitions.inserted_at` is `TIMESTAMPTZ NOT NULL DEFAULT NOW()`
  (`000022_media_state_machine_foundation.up.sql`).
- Cross-checked against sibling worker 8a (`media_cleanup_worker.ex`) and the sibling
  integration test (`media_cleanup_worker_integration_test.exs`).
- Cross-checked my own MEMORY.md for the recurring epic patterns: the
  anonymity-by-status-code class (1c/6a — not applicable, no download/HTTP surface here),
  the audit-allowlist-merge gotcha (4c/6a/8a/8c — checked, entry present), and the
  CaseClauseError-on-success class (8c — checked, does not recur here).

---

## Findings

| # | Severity | Location | Finding | Remediation |
|---|----------|----------|---------|-------------|
| 1 | LOW | `media_released_auto_delete_worker.ex:153-155` | `released_for_days/1` is evaluated OUTSIDE the per-row `rescue`, so a malformed `released_at` would abort the whole batch instead of isolating one row. Unreachable in production (column is `TIMESTAMPTZ NOT NULL`, WHERE clause filters NULLs), so no live poison-pill. | Optional hardening: move `released_for_days(released_at)` inside `process_row/…`'s rescue-wrapped body, or add a `released_for_days(nil)` guard. Not required for merge. |
| 2 | LOW | `media_released_auto_delete_worker.ex:187-195` | On `{:ok, :deleted}` the `AuditWriter.log/6` return value is discarded; if the audit write fails the state change persists without a compliance record ("state changed silently"). | Pre-existing, project-wide accepted pattern (identical to `Config.upsert/2` m2, `session_expiry_worker`, `user_deletion`, etc.); `AuditWriter.log` logs its own error internally. No change required — recorded for the audit trail, not a new 8d defect. |

No CRITICAL, HIGH, or MEDIUM findings.

---

## Detail — the blast-radius concerns AC1/AC3 exist to prevent

### `nil` is genuinely a total no-op (AC3) — verified, not assumed

`perform/1` → `validated_window/0` reads `Nebu.Media.Config.get().released_delete_after_days`
and pattern-matches `nil -> :disabled`. The `:disabled` arm returns `:ok` with **no**
`repo().query!`, no `StateMachine.transition/4`, no `AuditWriter.log`. Unit test 1 asserts
`repo_calls() == []` with a 400-day-old `:released` file present. Empirically airtight.

The `nil` default is defended in depth at three layers of `Nebu.Media.Config`:
1. `@defaults` ships `"released_delete_after_days" => nil`; `build_catalog/1` merges DB
   overrides *over* that default, so absence of a row leaves `nil` intact.
2. `coerce_value("released_delete_after_days", nil) -> nil` (read path).
3. `validate_value("released_delete_after_days", …)` (the only write path via `upsert/2`,
   ADR-020) accepts only `nil` or a non-negative integer; encode/decode round-trips `nil`
   through the empty-string sentinel (`""`→`nil`), never producing a spurious integer.

The only way a non-numeric value reaches `coerce_value/2`'s `String.to_integer/1` is a raw
SQL write bypassing `Config` entirely — out-of-contract for the whole `media_config` table.
The worker deliberately does not `rescue` `Config.get/0`: if that impossible value ever
existed, `perform/1` raising → Oban retry → dead-letter (fail loud) is the correct outcome,
strictly safer than guessing an active window. I concur with this reasoning.

### `0` / negative / non-integer never run as an active window (AC1)

`validated_window/0`: `days when is_integer(days) and days > 0 -> {:ok, days}`, everything
else → `:invalid` (log + no-op). `0`, `-5`, and `1.5` (a float — which `Config.coerce_value`
passes through unchanged because its only string clause is `String.to_integer/1`) all land
in `:invalid`. Unit test 7 confirms zero queries and zero transitions for each. A digit-only
string like `"30"` is correctly coerced to integer `30` by `Config` before the worker sees
it — not a bad value, and the test's own comment documents why it was removed from the bad
list. Correct.

### No early deletion — the whole-day floor gate errs toward retention

Deletion requires BOTH: (a) SQL `released_at < NOW() - (N || ' days')::interval`
(continuous-time age > N days), AND (b) the Elixir floor gate `released_for_days > days`,
i.e. `floor(age_seconds/86400) >= N+1`. The binding conjunction is (b): a file is only
deleted once it is **≥ N+1 whole days** old — strictly *later* than the naive N-day
boundary, never earlier. Elixir's `DateTime.utc_now()` runs a few ms/s after Postgres
`NOW()`, biasing age slightly larger, but that sub-second delta cannot bridge the 1-day
floor granularity. `inserted_at` being `TIMESTAMPTZ` (UTC) makes the Elixir `%DateTime{}`
comparison timezone-consistent with the SQL. Boundary tests 3 (29d untouched), 4 (exactly
30d untouched, strict `<`), 2 (31d deleted) confirm. The documented "up to one extra day of
retention" is real and is in the safe direction. **No off-by-one in the unsafe direction.**

### Soft-delete only — never hard-delete, never touches storage_key

The worker calls `StateMachine.transition(media_id, :deleted, {:system, nil}, …)`.
`StateMachine.write_transition/6` selects `@sql_update_state` (state column only) for any
`to_state` other than `:hard_deleted`; the `hard_deleted`-specific SQL that nulls
`storage_key`/`uploader_user_id` and stamps `hard_deleted_at` is unreachable from a
`:deleted` target. The worker never calls `MediaCleanupWorker` and never issues raw
`hard_deleted_at`/`storage_key` SQL (unit test 2 asserts the negative against the repo call
log). The `:deleted` rows it produces flow into 8a's own `deleted_days` eligibility on 8a's
*next* run — preserving a reversible grace/audit window. Confirmed against the call graph,
not just the moduledoc.

### AC4 audit integrity — one entry per successful transition, no silent gap on success

`transition/4` returns `{:ok, :deleted}` **only** after its `Repo.transaction/1` commits,
and the worker's `case` matches exactly `{:ok, :deleted}` (→ audit) and `{:error, reason}`
(→ log, no audit). There is no success shape other than `{:ok, :deleted}` for a `:deleted`
target, so — unlike 8c's `commit_archived/1` — there is no CaseClauseError-on-success path
that could change state while skipping the audit. Any unexpected return or raise is caught
by the per-row `rescue` and logged, with the transaction having rolled back (state
unchanged). The audit call uses the AC4-mandated actor
`"system:media_released_auto_delete_worker"`, action `media_released_auto_deleted`,
target_type `"media"`, target_id `media_id`, metadata
`%{released_delete_after_days:, released_for_days:}`, outcome `"success"` — all asserted by
unit test 5. The allowlist entry is present in `@known_actions` (this commit), so
`AuditWriter.log` will not reject the action — the exact 4c/6a/8a/8c allowlist gotcha,
correctly handled here. (Residual: audit-write *failure* after a committed transition is a
silent gap — see Finding 2, an accepted project-wide pattern.)

### Poison-pill / queue semantics — no new risk

`queue: :media_cleanup, max_attempts: 5` matches 8a/8c exactly. Per-row
`StateMachine.transition/4` failures (returned errors *or* raises) are isolated by the
`rescue` in `process_row/…`; `perform/1` unconditionally returns `:ok`, so a bad candidate
never fails the job or blocks the shared queue. The only whole-job failure path is
`Config.get/0` or `repo().query!` raising — an accepted fail-loud/dead-letter path, not
runaway retries. `LIMIT 1000` bounds each tick. No new poison-pill risk vs. the established
`:media_cleanup` queue characteristics.

### Integration test trigger-disable dance — established, accepted pattern

`media_released_auto_delete_worker_integration_test.exs` backdates a real
`media_state_transitions` row via a `nebu_migrate`-role
`DISABLE/ENABLE TRIGGER media_state_transitions_no_mutate` pair, wrapped in `try/after` so
the trigger is always re-enabled. This is byte-for-byte the same established pattern as
`media_cleanup_worker_integration_test.exs` (same role, same dev-only password
`nebu_migrate_dev_pw`, same `@moduletag :integration`, same NEBU_DB_URL gate that flunks
without a live DB). The hardcoded dev password is a pre-existing accepted convention for the
disposable docker-compose/CI database, not a new secret introduced by 8d. No new risk.

---

## Summary

- **CRITICAL:** 0
- **HIGH:** 0
- **MEDIUM:** 0
- **LOW:** 2 (both advisory; #1 unreachable-in-prod hardening, #2 pre-existing accepted
  project-wide pattern)

**Classification: CLEAN.** No commit-blocking findings. The `nil`-is-inert contract (AC1/AC3),
soft-delete-only guarantee (AC2), and one-audit-per-delete integrity (AC4) all hold under
adversarial inspection and are backed by empirical checks against the live schema and call
graph, not just the dev/code-review summaries.

No code was modified during this review — the two LOW items do not warrant editing
pipeline-protected `server/lib/` source outside a dev-story change, and Finding 1's failure
path is unreachable against the real `TIMESTAMPTZ NOT NULL` schema.
