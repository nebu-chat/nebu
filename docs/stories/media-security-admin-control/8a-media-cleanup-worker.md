---
story_id: 8a-media-cleanup-worker
title: "Retention & Cleanup: MediaCleanupWorker Hard-Delete Cron"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

**This story builds the SIMPLE, originally-scoped hard-delete cron — not the superseding
Story 13 Lifecycle Policy.** The epic's Review 5 (R-015/ADR-030) later redesigned retention as
a unified, admin-configurable **Media Lifecycle Policy** with **Two-Eyes-Delete** and
**Legal-Hold**, consolidating this story plus 8b/8c/8d/9b into `MediaLifecycleWorker` (Story
13c) and a dual-control approval flow (Story 13d). **Story 13 (13a–13f) is explicitly not being
built in this epic pass** — it is missing from `sprint-status.yaml` and tracked as follow-up
debt. This story therefore implements 8a exactly as it was originally scoped (a plain,
unconditional Oban-cron hard-delete for aged `:deleted`/`:infected` rows), **not** a preview or
partial implementation of the Story 13 design. There is no `legal_hold` column, no
`two_eyes_delete_required` gate, and no `compliance_officer` quorum here — those don't exist
in the schema yet (Story 13a would introduce them) and must not be speculatively added. When a
future epic builds Story 13, this worker is expected to be **replaced or migrated** into
`MediaLifecycleWorker` per ADR-030; this story's implementation is intentionally throwaway-safe
(a single, isolated module with no callers depending on its internals beyond the public
`Nebu.Media.StateMachine`/`Nebu.Media.Storage` calls it makes).

`Nebu.Workers.MediaCleanupWorker` is an Oban-cron (daily, 02:00 UTC) that finds `media_files`
rows that have sat in a soft-deleted state (`:deleted` — via Story 6a's `admin_delete/2`, or
`:infected` — via Story 4b's scan worker) past a per-state retention window, and permanently
removes them: the S3/MinIO object is deleted and the DB row is driven to `:hard_deleted` via
`Nebu.Media.StateMachine.transition/4` (Story 1b) — never a raw SQL `UPDATE`/`DELETE` against
`media_files.state`. Per the epic's DB-Record-Invariante, the `media_files` row itself is never
physically deleted; only `state`, `hard_deleted_at`, `storage_key`, and `uploader_user_id`
change. `media_state_transitions` rows for the file are permanent and untouched.

This story is also the **first delete path in the epic that touches both PostgreSQL and S3 for
the same file** (Story 1c's download gate only ever reads state; Story 2e's cleanup cron never
had bytes to delete). ADR-032's normative ordering — mark intent in Postgres, delete the S3
object, only then null the storage-referencing columns — is implemented here for the first
time, not reinvented; every later delete-touching story (8c, 13c, 13d) follows the same
sequence.

## User Story

As the Nebu server operator, I want files that have been soft-deleted (admin-deleted or
malware-infected) for longer than a configured retention window to be permanently and
irreversibly purged from object storage, so that the platform does not indefinitely retain
bytes for files that are no longer wanted or usable, while the compliance-relevant transition
history and audit trail for those files remain intact forever.

## Acceptance Criteria

1. **AC1 — Retention window config: default and source.** Two retention windows, matching the
   epic's original Story 8a scope bullet exactly: `deleted_days` (default **30**) for rows in
   `:deleted`, `infected_days` (default **7**) for rows in `:infected`. Source: a static
   `config :nebu, :media_cleanup, deleted_days: 30, infected_days: 7` entry in
   `server/config/config.exs`, read via `Application.get_env(:nebu, :media_cleanup, [])` with
   the same defaults as a fallback. This is **not yet** one of the `media_config` (Story 9a)
   keys surfaced in `/admin/media/settings` (Story 9b) — Story 9a/9b are not a dependency of
   this story (see Dependencies) and have not landed in this build order. When 9a lands, these
   two keys migrate from static config into the admin-configurable `media_config` table (the
   epic's own scope note: "Alle Retention-/Archiv-Werte sind über Story 9's `media_config`
   admin-konfigurierbar" — a forward-compat note, not something this story implements).
2. **AC2 — Cron schedule + queue.** `Nebu.Workers.MediaCleanupWorker` runs on an
   `Oban.Plugins.Cron` schedule, `"0 2 * * *"` (daily, 02:00 UTC), added to the `crontab:` list
   in `server/config/config.exs` alongside the entries Story 4b/2e already registered. Queue:
   `:media_cleanup` — the same shared queue Story 2e's `MediaReservedUploadCleanupWorker` uses
   (ADR-025), not a new queue.
3. **AC3 — Candidate selection, one query per source state.** Two read-only `SELECT`s (no
   `state` write in either):
   - `:deleted` candidates: `state = 'deleted' AND deleted_at < NOW() - (deleted_days || '
     days')::interval` — `deleted_at` is the dedicated per-state timestamp column Story 1a's
     migration adds, populated whenever a row enters `:deleted`.
   - `:infected` candidates: **no `infected_at` column exists** on `media_files` (Story 1a's
     migration adds `archived_at`/`deleted_at`/`hard_deleted_at` only — deviating here from the
     epic's terser "`deleted_at < NOW() - retention_interval` AND `state IN (:deleted,
     :infected)`" phrasing, which glossed over this). The age of an `:infected` row is instead
     derived from the append-only `media_state_transitions` ledger: the row's own
     `MAX(inserted_at)` for `to_state = 'infected'`, which is exactly the authoritative "when
     did this file become infected" record ADR-031 already guarantees can never be
     silently rewritten.
4. **AC4 — Hard-delete via `Nebu.Media.StateMachine`, never raw SQL on `state`.** For each fresh
   candidate from AC3, the worker calls
   `Nebu.Media.StateMachine.transition(media_id, :hard_deleted, {:system, nil}, metadata)`. Story
   1b's guard table only defines `deleted: [:hard_deleted]` and `infected: [:deleted]` — there is
   **no existing `infected → hard_deleted` edge**. This story adds that edge (a new
   `Nebu.Media.StateMachine` guard-table entry, `infected: [:deleted, :hard_deleted]`), the same
   kind of new-edge addition Story 2e already made for its own `:reserved → :hard_deleted` cron —
   see Technical Requirements and File List. `{:error, {:invalid_transition, _, _}}` (e.g. an
   admin already hard-deleted the row through some other path between query and transition) is
   treated as a no-op for that row, not a crash — matching the race-handling convention Story 2e
   already established for its own cron.
5. **AC5 — `hard_deleted_at` is set as a direct, non-`state` column write (ADR-032 step 1).**
   Per Story 1b's own scope (`transition/4`'s `UPDATE` touches only the `state` column — see
   Technical Requirements), the worker itself issues
   `UPDATE media_files SET hard_deleted_at = NOW() WHERE media_id = $1 AND hard_deleted_at IS
   NULL` immediately after a successful transition, **while `storage_key` is still populated**.
   This is not a violation of Story 1b's state-mutation invariant (the grep/DB-trigger guard
   only fires on `SET ... state =`) — the same precedent Story 4b/4c already established for
   the worker-owned, non-state `scan_metadata` column.
6. **AC6 — The S3 object is physically deleted (ADR-032 step 2).** The worker calls a new
   `Nebu.Media.Storage.delete/1` function (this story adds it — `get/1` and `put/2` are the only
   functions that exist today) with the row's `storage_key`, **before** nulling any DB column
   that references it. A `404`/not-found response from the object store is treated as `:ok` (the
   object is already gone — ADR-032: "re-issuing a delete against a non-existent S3 key is a
   safe no-op"). Any other error leaves the row exactly as-is (state already `:hard_deleted`,
   `hard_deleted_at` already set, `storage_key`/`uploader_user_id` still populated) for the next
   run to retry (AC8) — no partial DB write happens on a failed delete.
7. **AC7 — `storage_key`/`uploader_user_id` are nulled only after the S3 delete succeeds (ADR-032
   step 3).** `UPDATE media_files SET storage_key = NULL, uploader_user_id = NULL WHERE
   media_id = $1 AND storage_key IS NOT NULL`. The `WHERE storage_key IS NOT NULL` guard is what
   makes this — and the audit write that follows it — naturally idempotent (see AC8).
8. **AC8 — Idempotent under repeated runs, including recovery of a crashed prior run.** Running
   the job twice back to back, or interrupting it between AC5/AC6/AC7, must never error, never
   double-delete from S3 in a way that matters (a repeat delete of an already-gone key is a safe
   no-op per AC6), and never write a second audit entry for the same hard-delete. Concretely:
   - A row that already completed AC4–AC7 is excluded from every one of this story's queries
     (its `state` is no longer `:deleted`/`:infected`, and its `storage_key` is already `NULL`).
   - A row left in the **intermediate state** by a crashed or partially-failed prior run
     (`state = 'hard_deleted'` already, but `storage_key IS NOT NULL` — AC6 failed or the
     process died between AC5 and AC7) is picked up by a **third, "completion" query**
     (`state = 'hard_deleted' AND storage_key IS NOT NULL`) on the *next* run and carried through
     AC6/AC7 **without** re-attempting the AC4 state transition (the state is already correct).
     This is this story's minimal, in-worker implementation of the "reaper" concept ADR-032
     describes — full generality was assigned to Story 13c's `MediaLifecycleWorker`, which is
     out of scope for this epic pass (see Dev Agent Guardrails); folding the equivalent
     completion-sweep into this same cron tick is the pragmatic S-sized substitute so no delete
     is left permanently half-finished.
   - A failure processing one candidate row (e.g. one bad S3 credential/network blip) does not
     abort the whole tick — the worker processes each row independently (`rescue`-wrapped, same
     defensive style as `Nebu.Compliance.SessionExpiryWorker`) and logs+continues, so one row's
     failure can't block every other row's cleanup for a day.
9. **AC9 — Audit entry per successfully completed hard-delete.** A new audit action
   `"media_hard_deleted"` is written via `Nebu.Compliance.AuditWriter.log/6` — same public entry
   point, never a direct `Repo`/`AuditLogEntry` write from `Nebu.Media`/`Nebu.Workers` (ADR-020)
   — **after** AC7 completes successfully for that row (so a row that fails AC6/never reaches
   AC7 never gets an audit entry either — no compliance record for a delete that didn't actually
   happen yet). `actor_user_id` is the system sentinel `"system:media_cleanup_worker"`, matching
   the existing convention (`Nebu.Compliance.SessionExpiryWorker` uses
   `"system:compliance_worker"` for the same reason: no human user initiates a time-driven
   retention purge).
10. **AC10 — `AuditWriter.@known_actions` gains `media_hard_deleted` in the same commit —
    explicit, non-negotiable acceptance criterion.** `server/lib/nebu/compliance/audit_writer.ex`
    `@known_actions` gains `media_hard_deleted`, exactly the same known repo footgun Story
    4c/6a's ACs already flag: a new action string not present in the allowlist doesn't crash or
    500 — `AuditWriter.log/6` silently returns `{:error, :audit_unknown_action}` and the
    hard-delete event vanishes from the compliance record with no caller-visible failure (and,
    per AC9's "no rollback of state on audit failure" contract already established by 4c, the
    file *is* still gone from S3 either way — only the audit trail would silently lose the
    record).
11. **AC11 — `media_state_transitions` rows are exempt from all of this — permanent, per the
    epic's DB-Record-Invariante.** Nothing in this worker ever touches `media_state_transitions`
    directly beyond the one `INSERT` `transition/4` performs per successful `deleted →
    hard_deleted` or `infected → hard_deleted` transition (AC4); no row in that table is ever
    deleted or rewritten as a side effect of retention cleanup.
12. **AC12 — Out of scope, deliberately: no `legal_hold`/two-eyes/lifecycle-policy gating, no
    admin-facing dashboard counter, no manual "hard-delete now" trigger.** There is no
    `legal_hold` column on `media_files` today (Story 13a would add it) — this worker does not
    speculatively check for one. The "Hard-Delete-Zähler + Bytes-Freigabe im Admin-Dashboard"
    and "Admin kann Hard-Delete... manuell triggern" bullets from the epic's original Story 8a
    scope belong to Story 5a (dashboard) and Story 6a (admin actions) respectively as consumers
    of this worker's effects, not to this story's own build — this story ships only the
    automatic cron.

## Acceptance Tests

Test file: `server/test/nebu/workers/media_cleanup_worker_test.exs`, `use Oban.Testing, repo:
Nebu.Repo` (`Oban.Testing.perform_job/3` invoking `perform/1` directly), following the same
`FakeRepo`/injectable-collaborator convention Story 2e's and 4b's own test files already commit
to (also see `test/nebu/compliance/session_expiry_worker_test.exs` for the sibling
time-driven-worker precedent). Storage/StateMachine/AuditWriter are swapped for fakes via
`Application.get_env`-style seams (`:media_storage_module`, `:media_state_machine_module`,
`:compliance` `:audit_writer`/`:repo` — matching whichever seam names 1b/4b/session_expiry_worker
already establish).

1. `test "a :deleted row past deleted_days is hard-deleted: transitions to :hard_deleted, deletes the S3 object, and nulls storage_key/uploader_user_id"`
   — seeds a `:deleted` row with `deleted_at` older than `deleted_days`; asserts the fake
   `StateMachine.transition/4` was called with `(media_id, :hard_deleted, {:system, nil}, _)`;
   asserts the fake `Storage.delete/1` was called with the row's exact `storage_key`; asserts the
   fake DB shows `storage_key: nil, uploader_user_id: nil, hard_deleted_at: <non-nil>` after the run.
2. `test "an :infected row past infected_days (per media_state_transitions.inserted_at for to_state = infected) is hard-deleted"`
   — seeds an `:infected` row whose transition-log entry for `to_state = 'infected'` is older
   than `infected_days`; asserts the same transition/delete/null sequence as test 1.
3. `test "Nebu.Media.StateMachine.allowed?(:infected, :hard_deleted) is true and allowed_transitions(:infected) includes :hard_deleted"`
   — a direct, standalone test of the new guard-table edge this story adds (colocated in
   `server/test/nebu/media/state_machine_test.exs`, extending Story 1b's own test file, mirroring
   how Story 2e's guard-table-edge addition was verified), independent of whether the worker
   itself is exercised — proves the edge exists even if a future refactor of the worker stops
   calling it directly.
5. `test ":deleted rows within the retention window are left untouched"` — seeds a `:deleted`
   row with a recent `deleted_at`; asserts `StateMachine.transition/4` and `Storage.delete/1` are
   never called for it and no audit entry is written.
6. `test ":infected rows within the retention window are left untouched"` — mirrors test 5 for
   the transition-log-derived infected age.
7. `test "the job is idempotent under repeated runs: a row already fully hard-deleted (state hard_deleted, storage_key already NULL) is not reselected by any of the three candidate queries and produces zero further Storage.delete/StateMachine/audit calls"`.
8. `test "a row left in the intermediate state by a simulated crashed prior run (state already hard_deleted, storage_key still non-NULL) is completed by the next run's reaper/completion query — Storage.delete and the storage_key/uploader_user_id null happen, without re-invoking StateMachine.transition/4"`
   — proves AC8's self-healing sweep without re-attempting a transition the guard table would
   reject anyway (`hard_deleted` has no outgoing edges per 1b).
9. `test "S3 object removal is verified before the DB columns are nulled: Storage.delete/1 is called, and only on its success does the storage_key/uploader_user_id UPDATE run"`
   — using a call-order-asserting fake, proving ADR-032's ordering (delete-then-null, not the
   reverse) rather than just asserting both calls happened.
10. `test "a Storage.delete/1 failure leaves the row in the intermediate state, is logged, and does not write an audit entry or null storage_key/uploader_user_id — the row remains eligible for the next run's completion sweep"`
    (AC6/AC8/AC9 interaction).
11. `test "a failure processing one candidate row does not prevent other candidate rows in the same run from being hard-deleted"` — two candidates seeded, the fake `Storage.delete/1` raises/errors for the first and succeeds for the second; asserts the second row still completes fully.
12. `test "writes exactly one audit_log entry via AuditWriter with action \"media_hard_deleted\", actor_user_id \"system:media_cleanup_worker\", target_type \"media\", target_id = media_id, only after the S3 delete and column-null both succeeded"`.
13. `test "media_hard_deleted is present in AuditWriter.@known_actions"` — a direct, standalone
    allowlist assertion (not merely an indirect pass-through of test 12), mirroring Story
    4c/6a's dedicated regression test for this exact repo-known failure mode.
14. `test "the worker never issues a raw SQL UPDATE/DELETE against media_files.state — every state change is attributed to Nebu.Media.StateMachine.transition/4"`
    — asserts (via the `FakeRepo` call log, matching Story 2e's test 5 and Story 1b's own
    grep-invariant convention) that the only direct SQL this worker executes against
    `media_files` targets `hard_deleted_at`, `storage_key`, or `uploader_user_id` — never `state`.
15. `test "media_state_transitions rows are never modified or deleted by this worker"` — asserts
    the fake transition-log table's row count and contents for the test file are unchanged apart
    from the single new row `transition/4` itself inserts.

## Technical Requirements

- **Oban worker module:** `Nebu.Workers.MediaCleanupWorker`, in
  `server/lib/nebu/workers/media_cleanup_worker.ex`. `use Oban.Worker, queue: :media_cleanup,
  max_attempts: 5` — same queue as Story 2e's `MediaReservedUploadCleanupWorker` (ADR-025).
- **Cron entry** in `server/config/config.exs`'s existing `crontab:` list:
  ```elixir
  {"0 2 * * *", Nebu.Workers.MediaCleanupWorker}
  ```
- **Retention config:**
  ```elixir
  config :nebu, :media_cleanup,
    deleted_days: 30,
    infected_days: 7
  ```
  Read via `Application.get_env(:nebu, :media_cleanup, [])` with `Keyword.get(_, :deleted_days,
  30)` / `Keyword.get(_, :infected_days, 7)` fallbacks so the worker degrades safely even if the
  config block is ever omitted.
- **Candidate queries** (all read-only `SELECT`s, `LIMIT 1000` per the
  `SessionExpiryWorker`/Story 2e precedent so a single tick can't unboundedly scan the table):
  ```sql
  -- :deleted candidates
  SELECT media_id, file_hash, file_size, uploader_user_id, storage_key
    FROM media_files
   WHERE state = 'deleted'
     AND deleted_at < NOW() - ($1 || ' days')::interval
   LIMIT 1000

  -- :infected candidates (no infected_at column — derive age from the transition log)
  SELECT mf.media_id, mf.file_hash, mf.file_size, mf.uploader_user_id, mf.storage_key
    FROM media_files mf
   WHERE mf.state = 'infected'
     AND (SELECT MAX(t.inserted_at) FROM media_state_transitions t
           WHERE t.media_id = mf.media_id AND t.to_state = 'infected') < NOW() - ($1 || ' days')::interval
   LIMIT 1000

  -- completion/"reaper" candidates — rows left in the intermediate state by a prior partial run
  SELECT media_id, file_hash, file_size, uploader_user_id, storage_key
    FROM media_files
   WHERE state = 'hard_deleted'
     AND storage_key IS NOT NULL
   LIMIT 1000
  ```
- **New guard-table edge (`Nebu.Media.StateMachine`, Story 1b's module).** Story 1b's guard
  table ships with `infected: [:deleted]` only. This story adds `:hard_deleted` to that list —
  `infected: [:deleted, :hard_deleted]` — so the `@transitions` module attribute becomes:
  ```elixir
  infected: [:deleted, :hard_deleted]
  ```
  (all other entries unchanged). This is the same category of addition Story 2e already made
  for `reserved: [:quarantined, :hard_deleted]` — a new terminal edge for a retention/cleanup
  cron, not a restructuring of the guard mechanism. `deleted: [:hard_deleted]` already exists
  from 1b and needs no change.
- **Exact state-machine call** (AC4): `Nebu.Media.StateMachine.transition(media_id,
  :hard_deleted, {:system, nil}, %{reason: "retention_expired", from_state: from_state,
  retention_days: retention_days})` — `from_state` is `"deleted"` or `"infected"`, both now valid
  sources for the `:hard_deleted` edge per the guard-table addition above.
- **Non-state column writes** (AC5/AC7, direct `Ecto.Adapters.SQL.query/3` against `Nebu.Repo`,
  same inline-SQL convention as `Nebu.Media.DB`/`Nebu.Media.StateMachine`):
  ```sql
  UPDATE media_files SET hard_deleted_at = NOW()
   WHERE media_id = $1 AND hard_deleted_at IS NULL;

  UPDATE media_files SET storage_key = NULL, uploader_user_id = NULL
   WHERE media_id = $1 AND storage_key IS NOT NULL;
  ```
- **S3 delete call** (AC6) — new function on `server/lib/nebu/media/storage.ex`:
  ```elixir
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    bucket()
    |> ExAws.S3.delete_object(key)
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> :ok  # already gone — safe no-op, ADR-032
      {:error, reason} -> {:error, reason}
    end
  end
  ```
- **Audit call site** (AC9/AC10):
  ```elixir
  Nebu.Compliance.AuditWriter.log(
    "system:media_cleanup_worker",
    "media_hard_deleted",
    "media",
    media_id,
    %{from_state: from_state, file_hash: file_hash, bytes_freed: file_size,
      uploader_user_id: uploader_user_id, retention_days: retention_days},
    "success"
  )
  ```
  called only after the AC7 `UPDATE` affects a row (i.e. the `storage_key IS NOT NULL` guard
  matched — proving this call site hasn't already run for this media_id).
- **Per-row isolation:** each candidate row is processed inside its own `rescue`-wrapped block
  (mirrors `Nebu.Compliance.SessionExpiryWorker`'s defensive style), logging via `Logger.error`
  and continuing to the next row on failure, so the whole cron tick's `perform/1` always
  returns `:ok` — matching the existing time-driven-worker convention in this codebase rather
  than surfacing per-row S3/DB errors as an Oban-level job retry (the *next day's* completion
  query is this worker's own retry mechanism for a row stuck in the intermediate state).

## File List

| File | Change Type |
|---|---|
| `server/lib/nebu/workers/media_cleanup_worker.ex` | NEW — the Oban worker |
| `server/lib/nebu/media/state_machine.ex` | UPDATE — add the `infected → hard_deleted` guard-table edge (`infected: [:deleted, :hard_deleted]`) |
| `server/lib/nebu/media/storage.ex` | UPDATE — add `delete/1` |
| `server/config/config.exs` | UPDATE — add the cron entry and `config :nebu, :media_cleanup, ...` |
| `server/lib/nebu/compliance/audit_writer.ex` | UPDATE — add `media_hard_deleted` to `@known_actions` |
| `server/test/nebu/workers/media_cleanup_worker_test.exs` | NEW — Acceptance Tests above |
| `server/test/nebu/compliance/audit_writer_media_actions_test.exs` | UPDATE (if Story 4c/6a already created this file) or NEW — allowlist regression test for `media_hard_deleted`, in the shape of `audit_writer_member_actions_test.exs` |

## Dev Agent Guardrails

### Do Not Change

- **Never issue a raw SQL `UPDATE` or `DELETE` against `media_files.state`.** The only legal
  write path into `state` is `Nebu.Media.StateMachine.transition/4`. This worker's own two
  direct `UPDATE`s (AC5/AC7) touch `hard_deleted_at`/`storage_key`/`uploader_user_id` only —
  never `state` — exactly the same non-state-column carve-out Story 4b/4c's `scan_metadata`
  write already established, and exactly the boundary Story 1b's grep invariant test checks for.
  Do not weaken or special-case that grep test for this story's new file.
- **Do not implement Story 13's Lifecycle Policy, Two-Eyes-Delete, or Legal-Hold here.** No
  `legal_hold` check (the column doesn't exist yet — Story 13a would add it), no
  `two_eyes_delete_required` gate, no `compliance_officer` quorum, no `proposed → confirmed`
  dual-control flow, no scoped (`global`/`space`/`room`) policy document, no archive-tier rung.
  This worker unconditionally hard-deletes every row past its retention window — that
  unconditional behavior is *by design* for this epic pass and is expected to be replaced when a
  future epic builds Story 13c's `MediaLifecycleWorker` per ADR-030. Do not attempt to
  future-proof this module with speculative hooks for the Story 13 design (e.g. an unused
  `legal_hold` guard clause referencing a nonexistent column) — build exactly this story's scope.
- **Do not build Story 8b (Orphan-Detection)**, **8c (archive-tier)**, or any other 8-series
  sibling. This story only ever selects from `state IN ('deleted', 'infected')` plus its own
  completion sweep; it does not touch `:quarantined`/orphan detection or `:released`/archival at
  all.
- **Do not add the admin-dashboard hard-delete counter (Story 5a) or a manual "hard-delete now"
  admin trigger (Story 6a).** Those are separate stories' scope; this worker is the automatic
  cron only. If a manual trigger is later wanted, it should call into the same
  `Nebu.Media.StateMachine`/`Nebu.Media.Storage` primitives this worker uses, not duplicate them
  — but building that admin action is out of scope here.
- **Do not skip the `AuditWriter.@known_actions` update in the same commit.** This is the exact
  repo-known failure mode Story 4c/6a's ACs already documented (a merged branch once dropped
  `member_added`/`member_removed`/`room_visibility_changed` from the allowlist, silently
  breaking the audit trail — see `audit_writer_member_actions_test.exs`). Code review must
  independently verify `media_hard_deleted` is present in `@known_actions`, not merely assume
  "tests pass" covers it.
- **Do not reorder ADR-032's three steps.** `hard_deleted_at`/state-transition, *then* the S3
  delete, *then* the `storage_key`/`uploader_user_id` null — never null the storage-referencing
  columns before the object is confirmed deleted (or confirmed already-gone via a 404). A
  dangling DB reference to a blob that no longer exists is the failure mode ADR-032 explicitly
  chose to avoid at the cost of tolerating a temporarily orphaned blob instead.
- **`server/lib/nebu/media/state_machine.ex`, `crypto.ex`, `db.ex`** — call their public APIs
  only; do not reimplement transition-guard logic, encryption, or row lookups inline in this
  worker.

## Dependencies

- **1a — `media_files`/`media_state_transitions` migration** — provides the `deleted_at`/
  `hard_deleted_at`/`storage_key` columns this worker reads and writes, and the
  `media_state_transitions` table this worker derives `:infected` row age from.
- **1b — `Nebu.Media.StateMachine`** — provides `transition/4` and the `deleted -> hard_deleted`
  guard-table edge this worker's sole state-mutation call site relies on for `:deleted` rows.
  This story itself adds the sibling `infected -> hard_deleted` edge (see Technical
  Requirements/File List) — 1b must have landed first so this story extends an existing
  `@transitions` map rather than introducing the guard mechanism.
- **6a-routine-state-actions** — `Nebu.Media.admin_delete/2` is what actually produces the
  `:deleted` rows this cron cleans up (via a soft-delete from `:quarantined`/`:released`/
  `:admin_blocked`/`:infected`); Story 4b's scan worker independently produces the `:infected`
  rows. This story is a downstream consumer of both — it does not create either source state
  itself.

**Not a dependency (forward-compat note only, AC1):** Story 9a's `media_config` table/Story
9b's `/admin/media/settings` UI would eventually take over as the source for `deleted_days`/
`infected_days`, but this story ships with static `config.exs` defaults and does not wait on
9a/9b to land first.

**Superseded-by (not built in this epic pass):** Story 13c's `MediaLifecycleWorker` (ADR-030)
consolidates this worker plus Stories 8c/8d into one policy-driven engine, and Story 13d's
Two-Eyes-Delete removes this worker's unconditional automatic hard-delete once
`two_eyes_delete_required` is enabled. Both are tracked as follow-up debt, missing from
`sprint-status.yaml`, and out of scope here.

## Dev Agent Record

### Corrections

- **AC3's `:deleted` candidate query, as originally specified above (`deleted_at < NOW() -
  (deleted_days || ' days')::interval`), is NON-FUNCTIONAL in production and was corrected before
  commit (security-review fix cycle 2, Kassandra F-1/MEDIUM, 0 CRITICAL/0 HIGH otherwise).**
  `media_files.deleted_at` is never populated by any code path: `Nebu.Media.admin_delete/2`
  (Story 6a, `server/lib/nebu/media.ex`) calls `StateMachine.transition(media_id, :deleted,
  {:admin, admin_id}, %{})`, and `Nebu.Media.StateMachine.transition/4`'s generic
  `@sql_update_state` (used for every transition target except `:hard_deleted`, which gets its own
  special-cased SQL variant that additionally stamps `hard_deleted_at`) only ever does `UPDATE
  media_files SET state = $2` — no `:deleted`-specific column stamp exists anywhere in
  `transition/4`. Since `deleted_at` is therefore always `NULL` in every real row, and `NULL < x` is
  never true in Postgres, the AC3 predicate as originally written matched **zero rows forever** —
  admin-soft-deleted media was never hard-deleted by this worker, silently defeating half of this
  story's stated purpose (the `:infected` half was unaffected — see below). This survived ATDD,
  test-review, CI, and code-review because every test in
  `server/test/nebu/workers/media_cleanup_worker_test.exs` used a `FakeRepo` that directly SEEDS
  `deleted_at` on the fake row and filters on it — presupposing exactly the population that doesn't
  exist in production; a per-story fake could not see this cross-story seam gap.

  **Fix shipped (option (b), symmetric with the sibling `:infected` query):** the `:deleted`
  candidate age is now derived from the append-only `media_state_transitions` ledger instead —
  `(SELECT MAX(t.inserted_at) FROM media_state_transitions t WHERE t.media_id = mf.media_id AND
  t.to_state = 'deleted') < NOW() - ($1 || ' days')::interval` — exactly the same shape AC3's own
  `:infected` query already uses (`to_state = 'infected'`), which `transition/4` genuinely populates
  for every transition (ADR-031: this ledger table is the authoritative, trigger-protected,
  immutable source of "when did this row enter this state"). This fix is confined entirely to
  `server/lib/nebu/workers/media_cleanup_worker.ex`'s own `:deleted` candidate SELECT — no change to
  `Nebu.Media.StateMachine.transition/4`, `admin_delete/2`, the migration, or any other shared code
  path other stories depend on. The moduledoc's "Three candidate queries" section is corrected to
  match. A new real-DB regression test
  (`server/test/nebu/workers/media_cleanup_worker_integration_test.exs`, `@moduletag :integration`)
  drives the actual `Nebu.Media.admin_delete/2` → `Nebu.Media.StateMachine.transition/4` →
  `Nebu.Workers.MediaCleanupWorker.perform/1` path against a live PostgreSQL (backdating the real
  `media_state_transitions` ledger row's `inserted_at` for `to_state = 'deleted'`, since `now()`
  itself can't be backdated) — this is the test that would have caught the original bug, since it
  exercises real production code paths end-to-end rather than a fake that already assumes the fix.

- **Additional bug found (and fixed) while writing the new real-DB test, orthogonal to F-1:** both
  `@sql_select_deleted_candidates` and `@sql_select_infected_candidates` bind `$1` inside `($1 ||
  ' days')::interval`. Postgres resolves `$1`'s parameter type as `text` for that concatenation (to
  match the `' days'` text literal), so Postgrex requires a binary for it — but
  `process_fresh_candidates/3` was binding the raw Elixir integer `retention_days`. Every real
  invocation of this worker crashed with `DBConnection.EncodeError` before ever reaching either
  candidate query's `WHERE` predicate — a strictly worse, previously-undetected bug than F-1 (F-1
  only silenced the `:deleted` half; this crashed the whole cron tick, `:infected` and completion
  sweep included). Undetected until now because every prior test used a `FakeRepo` that never
  round-trips real SQL/real parameter encoding. Fixed by binding `Integer.to_string(retention_days)`
  instead (SQL text unchanged) — a minimal, mechanical fix at the one shared call site, verified by
  the new real-DB test above, which fails without it and passes with it.
