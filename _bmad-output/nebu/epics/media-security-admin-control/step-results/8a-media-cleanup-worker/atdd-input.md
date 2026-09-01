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
