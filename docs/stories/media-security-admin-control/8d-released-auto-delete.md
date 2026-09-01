---
story_id: 8d-released-auto-delete
title: "Retention & Cleanup: released_delete_after_days Auto-Delete"
epic: media-security-admin-control
status: done
security_review: optional
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 8a's `MediaCleanupWorker` hard-deletes files that already left the "actively good" lane
(`:deleted`, `:infected`). This story adds the fourth and last retention lever from Story 8's
split: an **optional** data-minimization window for files that were **never flagged by anything**
— clean, `:released`, never-complained-about attachments that have simply been sitting there for a
long time. Per the epic (Winston-Review 3, resolving Offene-Entscheidung #8), this is explicitly
**not a security feature** — it exists purely so an operator can honor a data-minimization policy
("we don't keep media forever") without keeping every released file indefinitely by default.

The blast radius here is categorically larger than 8a/8b/8c: those workers only ever touch files
that are already in a negative or archival state. This worker, if misconfigured, would routinely
destroy files every room member can currently still see and download. The single config value
`released_delete_after_days` therefore carries the strongest "must default to fully off, and stay
off unless an admin explicitly opts in" contract of any value in this epic. `nil` is the only safe
default, and `nil` must mean *nothing runs* — not "run with a window of zero."

This story's own scope is intentionally narrow: it owns the worker path only (config read +
cron + soft-delete transition + audit). The UI warning that must accompany turning this on
(Story 9b, `/admin/media/settings`) is out of scope here — this package assumes the config value
already has some valid value (nil or a positive integer of days) by the time the worker runs.

## User Story

As an operator running Nebu under a data-minimization policy, I want to optionally configure a
maximum age for `:released` media files after which they are automatically retired, so that
long-forgotten but never-problematic attachments don't accumulate indefinitely — while trusting
that this stays completely inert unless I explicitly turn it on.

## Acceptance Criteria

1. **AC1 — `released_delete_after_days` config value, default `nil` (disabled).** The value is
   read once per cron tick (or via a cached config read, matching whatever config-access pattern
   is available at implementation time — see Technical Requirements). `nil` is the only value that
   means "feature disabled." Any other falsy-but-technically-present value some future refactor
   might introduce (e.g. `0`, `""`, `false`) must **not** be silently treated as "disabled" *or* as
   "delete everything immediately" — only `nil` is disabled, and only a positive integer number of
   days is a valid enabled window. A non-`nil`, non-positive-integer value must not be interpreted
   as an active window; the worker must refuse to run in that case (log and no-op) rather than
   guess an interpretation, since guessing wrong in either direction is a data-loss or
   silently-broken-feature bug.
2. **AC2 — When set, a cron transitions eligible `:released` files to the soft-deleted state via
   `Nebu.Media.StateMachine`, not a direct hard-delete.** Eligibility: `state = :released` and
   `released_at` (or the state's entry timestamp — see Technical Requirements for the exact column)
   older than `NOW() - released_delete_after_days` (interval). The worker calls
   `Nebu.Media.StateMachine.transition/4` with target `:deleted` and `actor: {:system, nil}` (the
   same system-actor shape Story 4b's worker uses for its own transitions) — it never writes
   `storage_key = NULL` / `hard_deleted_at` / `state = :hard_deleted` itself. Story 8a's
   `MediaCleanupWorker` is the **only** place bytes are actually destroyed; this story only ever
   produces `:deleted` rows, which flow into 8a's existing `deleted_days`-based eligibility query on
   its next run.
3. **AC3 — Disabled by default.** With `released_delete_after_days = nil` (the shipped default),
   the cron tick is a complete no-op: no query beyond reading the config value, no
   `StateMachine.transition/4` call, no `media_state_transitions` row, no audit entry — regardless
   of how old any `:released` file in the database is. A fresh install with old seed/test data must
   never lose files to this worker.
4. **AC4 — Every auto-delete transition writes an audit entry.** Action `media_released_auto_deleted`
   (register in `AuditWriter.@known_actions` in the same commit — the same allowlist gotcha Story
   4c/6a both flag: a missing allowlist entry doesn't error, it silently drops the compliance
   record while the state transition itself still succeeds). `actor_user_id: "system:media_lifecycle"`
   (or the equivalent system-actor identifier already established by a sibling worker at
   implementation time — mirror whatever `Nebu.Compliance.SessionExpiryWorker` /
   `Nebu.Workers.MediaCleanupWorker` (8a) settled on for consistency), `target_type: "media"`,
   `target_id: media_id`, `metadata: %{released_delete_after_days: <value used>, released_for_days: <actual age>}`,
   `outcome: "success"`.

## Acceptance Tests

Test file: `server/test/nebu/workers/media_released_auto_delete_worker_test.exs` (unit-level Oban
worker test, following the `Nebu.Compliance.SessionExpiryWorker`/Oban-cron-test conventions already
used elsewhere in this epic — fake config source, fake repo/state-machine seam, `perform/1` invoked
directly rather than waiting on the real cron schedule):

1. `test "disabled by default: released_delete_after_days = nil is a no-op even with old :released files present"` —
   seeds one or more `:released` files with a `released_at`/entry timestamp far in the past (e.g.
   400 days), config returns `nil`, runs the worker, and asserts: zero `StateMachine.transition/4`
   calls, zero new `media_state_transitions` rows, zero new `audit_log` entries, and the file(s)
   remain `:released` in the fake state.
2. `test "enabled with a window correctly soft-deletes eligible files"` — config returns e.g. `30`,
   seeds a `:released` file whose entry timestamp is 31 days old, runs the worker, and asserts
   exactly one `StateMachine.transition/4` call to `:deleted` with `actor: {:system, nil}` (or the
   established system-actor shape) for that file's `media_id`.
3. `test "files younger than the window are untouched"` — same `30`-day config, seeds a `:released`
   file whose entry timestamp is 29 days old (and, as a boundary check, one at exactly 30 days —
   assert the documented inclusive/exclusive boundary consistently with Story 8a's own
   `deleted_days`/`infected_days` boundary semantics), runs the worker, and asserts no
   `StateMachine.transition/4` call for that file.
4. `test "audit entry test: each auto-deleted file writes exactly one media_released_auto_deleted audit_log entry with actor system, target_type media, and metadata containing the configured window"` —
   covers AC4 directly (not just as a side effect of test 2), including an explicit assertion that
   `media_released_auto_deleted` is present in `AuditWriter.@known_actions` (mirrors 6a's own
   direct-allowlist-assertion pattern, test 9 in `6a-routine-state-actions.md`), so a future
   refactor that drops the allowlist entry fails loudly here rather than as a swallowed
   `{:error, :audit_unknown_action}` deep inside the worker.
5. `test "a non-nil, non-positive-integer config value (e.g. 0 or a negative number) does not run as an active window — worker logs and no-ops rather than treating it as delete-immediately"` (AC1)
   — guards specifically against the "0 read as falsy-but-active" failure mode called out in the
   epic and in this story's Dev Agent Guardrails.

## Technical Requirements

### Config source: `media_config` (Story 9a) with an app-env fallback

`released_delete_after_days` is one of the policy values Story 9a's `media_config` table /
`Nebu.Media.Config` module (`get/0`, DB-override-with-`config.exs`-fallback) is designed to hold.
**Explicit dependency/coordination note:** if Story 9a has not yet landed when this story is
implemented (build-order is not strictly enforced across the 40-package split, and 8d is
"4 von 4" in the 8-split while 9a is "1 von 3" in the 9-split — these can, in principle, be worked
in either order), this story must not block on it. Fallback: read the value from a plain
`Application.get_env(:media, :released_delete_after_days, nil)` app-env default (matching the
epic's stated default of `nil`), and switch the read to `Nebu.Media.Config.get().released_delete_after_days`
once 9a's module exists — this is a one-line change confined to this worker's config-read call
site, not a redesign. Do **not** invent a second, competing config table or a bespoke ETS cache for
this single value while waiting for 9a; the app-env fallback is intentionally the simplest possible
placeholder.

### `Nebu.Workers.MediaReleasedAutoDeleteWorker` (Oban cron)

- Registered as an Oban cron job (same daily `02:00 UTC` rhythm 8a/8c already use for retention
  crons — check in with whichever of 8a/8c has landed first for the exact cron-plugin config
  block/module naming convention already established, and follow it rather than introducing a
  second Oban cron registration pattern).
- `perform/1` (or the tick entry point, depending on whether this ships as an Oban `Worker` or a
  stateless GenServer tick per the `SessionExpiryWorker` pattern — prefer Oban, since 8a/8c are
  already Oban-based and this worker's failure/retry semantics should match its siblings):
  1. Read `released_delete_after_days` (see config source above). If `nil` → return `:ok`
     immediately, no query, no side effect (AC3). If present but not a positive integer → log an
     error and return `:ok` (no-op) rather than guessing an interpretation (AC1).
  2. Query `media_files` for `state = 'released'` and entry-timestamp older than the computed
     cutoff. Use the column that marks when the file *became* `:released` — verify against
     `1a-media-files-migration.md`'s actual schema (likely a `released_at` timestamp, or derivable
     from the most recent `:released` row in `media_state_transitions` if no dedicated column
     exists) rather than assuming a column name; do not add a new column for this if an equivalent
     timestamp already exists from 1a.
  3. For each eligible file: call `Nebu.Media.StateMachine.transition(media_id, :deleted, {:system, nil}, metadata)`
     (AC2) — through `Nebu.Media`'s public API if 6a's `Nebu.Media.admin_delete/2`-style wrapper
     convention is preferred for consistency, or directly against `StateMachine` if this worker
     follows the same-namespace pattern Story 4b's scan worker already uses (system-driven
     transitions called from within `Nebu.Media`/its workers do not need to go through the
     `Nebu.Admin`-facing wrapper functions — that indirection is ADR-020's cross-*namespace* rule,
     and this worker lives in the same `Nebu.Media` namespace as `StateMachine`).
  4. On `{:ok, :deleted}`: call `Nebu.Compliance.AuditWriter.log/6` with
     `action: "media_released_auto_deleted"` (AC4).
  5. Per-file failures (a single `StateMachine.transition/4` error) must not abort the whole batch
     — log and continue to the next file, consistent with 8a's cohort-processing behavior.

### State machine

No new guard-table edge is required: `:released → :deleted` already exists in Story 1b's guard
table (it is the same edge Story 6a's `admin_delete/2` already uses). This story is a new *caller*
of that existing edge, driven by a cron instead of an admin click, with `actor: {:system, nil}`
instead of an admin id.

## File List

| File | Change Type |
|---|---|
| `server/lib/nebu/workers/media_released_auto_delete_worker.ex` | NEW |
| `server/lib/nebu/compliance/audit_writer.ex` | UPDATE — add `media_released_auto_deleted` to `@known_actions` |
| `server/test/nebu/workers/media_released_auto_delete_worker_test.exs` | NEW |
| `config/config.exs` (or equivalent) | UPDATE — `released_delete_after_days` app-env default (`nil`), used only until 9a's `Nebu.Media.Config` exists |

## Dev Agent Guardrails

### Do Not Change

- **`nil` must mean fully disabled — do not accidentally treat `nil` as `0` or "delete
  immediately."** There is no valid reading of "unset" as an active zero-day window. If the config
  read ever returns something ambiguous, the safe failure mode is always "do nothing," never "act
  as aggressively as possible."
- **Never call the hard-delete path directly from here.** This worker only ever produces
  `:released → :deleted` (soft-delete) transitions via `Nebu.Media.StateMachine`. It must never set
  `storage_key = NULL`, `hard_deleted_at`, or `state = :hard_deleted` itself, and must never call
  anything in `Nebu.Workers.MediaCleanupWorker` (8a) directly. Always go through the soft-delete
  state and let 8a's existing `deleted_days`-based cron perform the actual byte-level removal on
  its own schedule — this preserves a grace/audit window (an admin can still notice and reverse a
  wrongly-configured window, e.g. by lowering it back and restoring from `:deleted`, before 8a's
  cron makes it permanent) rather than compounding this story's already-larger blast radius with an
  immediate, irreversible hard-delete.
- **Do not implement the Settings-UI warning for setting `nil` → a concrete value.** That belongs
  to Story 9b (`/admin/media/settings`). This package is the worker path only.
- **Do not invent a second config-storage mechanism while 9a is pending.** Use the plain app-env
  fallback described above; do not build a bespoke table, ETS cache, or file-based config just to
  avoid the 9a dependency.

## Dependencies

**Depends on:**

- `1a-media-files-migration` / `1b-state-machine-module` — provides `media_files`, the
  `:released`-entry timestamp this worker's eligibility query reads, and
  `Nebu.Media.StateMachine.transition/4` with the existing `:released → :deleted` guard-table edge.
- `9a-media-config-table-module` — the intended long-term source of `released_delete_after_days`.
  **Coordinate on build order:** if this story (8d) is implemented before 9a lands, use the app-env
  fallback described in Technical Requirements and leave a one-line TODO pointing at the eventual
  `Nebu.Media.Config.get/0` switch-over; do not block 8d on 9a merging first.
- `8a-media-cleanup-worker` — the downstream consumer of the `:deleted` state this story produces.
  8d does not duplicate or race with 8a's hard-delete cron; it only ever feeds 8a's existing
  eligibility query a new cohort of `:deleted` rows.

**Downstream:** Story 9b's settings UI is expected to surface `released_delete_after_days` with a
strengthened confirmation warning when changing it from `nil` to a concrete value; 9b does not need
to know anything about this worker's internals beyond the config key name.

## Dev Agent Record

### Completion Notes

Implemented against the pre-research ground-truth doc, NOT this story's own (stale) Technical
Requirements section — Story 9a had already landed by implementation time:

- Config read is `Nebu.Media.Config.get().released_delete_after_days` directly (no app-env
  fallback path, no bespoke config mechanism). The worker additionally enforces its own
  positive-integer gate on top of Config's looser storage-level validator (which accepts `0`),
  per AC1.
- Eligibility age is derived from `media_state_transitions` (`MAX(inserted_at) WHERE to_state =
  'released'`), mirroring `MediaCleanupWorker`'s (8a) `:deleted`/`:infected` query shape exactly,
  including the `Integer.to_string/1` interval-binding gotcha.
- A precise, floored whole-day recheck (`released_for_days > days`) gates the actual
  transition/audit call after the SQL's coarser millisecond-granular candidate filter — needed
  because real wall-clock time always advances between when a row entered `:released` and when
  the tick runs the query, which would otherwise flag a file exactly `released_delete_after_days`
  old as already fractionally past the cutoff (violates the test's documented inclusive boundary).
- `Nebu.Media.StateMachine.transition/4` → `:deleted`, `actor: {:system, nil}`; never a direct
  hard-delete; never calls `MediaCleanupWorker` (8a).
- `media_released_auto_deleted` added to `AuditWriter.@known_actions` in the same commit.
- Oban cron: added third `{"0 2 * * *", Nebu.Workers.MediaReleasedAutoDeleteWorker}` tuple to
  `config/config.exs`'s existing crontab list, alongside 8a/8c.
- No new migration; no new `MigrationsGrantTest` entry (confirmed — `media_config`, `media_files`,
  `media_state_transitions` already granted from prior migrations).

**Known test-file discrepancy (documented, not fixed):** test 7's parametrized bad-value loop
`[0, -5, "30", 1.5]` includes the string `"30"` on the assumption (stated in the test's own inline
comment) that the `:media_config_source` seam "bypasses `Nebu.Media.Config`'s own coerce/validate."
Verified empirically against `server/lib/nebu/media/config.ex` that this is incorrect:
`Config.get/0` calls `build_catalog/1` unconditionally (seam or real DB path alike), and
`build_catalog/1`'s `coerce_value("released_delete_after_days", v)` converts ANY binary value via
`String.to_integer/1` — so `"30"` is coerced to the integer `30` before this worker ever sees it,
identically to how a real `media_config` DB row (always stored as TEXT) would decode. This makes
`"30"` indistinguishable from a legitimately-configured `30` by the time `Config.get/0` returns,
for both the test seam and real production. Satisfying this one sub-case would require either (a)
bypassing `Nebu.Media.Config`'s public API to peek at the raw seam value (violates this story's own
explicit "Config is the sole source of truth" guardrail), or (b) loosening Config's own coercion
(out of scope, would touch story 9a's already-shipped, already-tested contract). Left unfixed;
7/8 tests pass in this file, all 5 acceptance criteria are satisfied per the verified real behavior
of `Nebu.Media.Config`. The other three bad values in the same loop (`0`, `-5`, `1.5`) all pass,
since none of them are binaries and so are not silently coerced.

### File List

- `server/lib/nebu/workers/media_released_auto_delete_worker.ex` (NEW, 207 lines; cycle 1: moduledoc
  comment above `process_row/3` corrected)
- `server/lib/nebu/compliance/audit_writer.ex` (UPDATE — added `media_released_auto_deleted` to
  `@known_actions` + moduledoc comment)
- `server/config/config.exs` (UPDATE — added third Oban cron tuple)
- `server/test/nebu/workers/media_released_auto_delete_worker_integration_test.exs` (NEW, cycle 1 —
  real-Postgres regression test for `released_for_days/1`'s `%DateTime{}` clause)

### Change Log

- 2026-07-19: Implemented `Nebu.Workers.MediaReleasedAutoDeleteWorker` per AC1-AC4 and the
  pre-research ground-truth doc (9a-aware config read, ledger-derived eligibility, soft-delete-only
  transition, per-row failure isolation, audit bridge). Registered daily Oban cron. 7/8 unit tests
  green (1 known Config-coercion test-file discrepancy documented above, non-blocking).
- 2026-07-19 (cycle 1, code-review fix): Corrected the `process_row/3` doc comment, which implied
  the Elixir-side floor gate merely reproduces 8a's own boundary semantics ("mirrors 8a"). 8a has no
  such Elixir-side floor gate — its only boundary is the SQL's sub-day `<` comparison. 8d's real,
  effective deletion boundary is therefore "more than `released_delete_after_days` FULL/whole days
  old" (up to one extra whole day of retention beyond the raw config value in the worst case), a
  deliberate safety-biased choice, not literal parity with 8a. (`config.exs`'s own 8d cron comment
  was checked and does not make a boundary-parity claim — only a cadence/query-disjointness one — so
  it was left unchanged.) Also added
  `media_released_auto_delete_worker_integration_test.exs`, a real-Postgres `@moduletag :integration`
  test exercising `released_for_days/1`'s `%DateTime{}` clause (previously only the unit suite's
  integer-ms clause was covered) — verified green via `make`-equivalent `docker compose up` +
  `mix test --include integration` against a live stack.
