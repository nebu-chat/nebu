---
story_id: 8c-media-archive-worker
title: "Retention & Cleanup: MediaArchiveWorker Archive Tier"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

`:released` media that nobody has downloaded in a long time still occupies the same
(expensive) primary S3/MinIO bucket as freshly-uploaded, actively-served files. This story
adds `Nebu.Workers.MediaArchiveWorker`, an Oban-cron job that copies aged `:released` objects
into a cheaper, separately-configured **archive bucket** and records the move as
`archived_at` on the `media_files` row — without touching the lifecycle `state` at all.

**Resolved mechanism (per the epic's own Story 8c bullet, ADR-029, and ADR-030's rung
table):** this is a **bucket-to-bucket server-side copy** (`ExAws.S3.put_object_copy/5`
against a second, admin-configured bucket from Story 11b), **not** an S3 storage-class
transition (e.g. Standard → Glacier/Infrequent-Access). Nebu's `Nebu.Media.Storage` module
has no notion of storage classes today, and neither the epic text, ADR-029, nor ADR-030
introduce one — "cheaper tier" here means "a different, presumably cheaper-priced bucket the
operator points at," resolved once at read time by an `archived_at IS NULL` bucket switch, not
a class-transition with retrieval latency. See Dev Agent Guardrails for why a cold-storage
retrieval-latency variant is explicitly out of scope.

Because the bytes are already AES-256-GCM-encrypted (key/nonce live in the DB row, never in
S3), the copy is a byte-for-byte server-side operation — no download, no decrypt, no
re-encrypt, no re-upload. `storage_key` itself does **not** change (ADR-029: the key is
computed once at upload time and never recomputed); only which *bucket* a reader must consult
changes, driven by whether `archived_at` is set. Story 1c's download-gate enforcement
(`Nebu.Media.download/4` → `with_authorised_media/4` → `fetch_and_decrypt/3`) was written
before this story existed and has no bucket-switch logic at all — closing that gap for the
download path is explicitly part of this story's scope, not a follow-up.

**Epic-level note on Story 13 (read before treating this as throwaway work):** the epic's own
Review 5 (R-015 / ADR-030, currently status *Proposed/DRAFT*) flags that the three retention
crons introduced by Stories 8a/8c/8d will eventually be consolidated into one
`Nebu.Workers.MediaLifecycleWorker` (Story 13c), which explicitly says it reuses "the 8c
technique (server-side copy, no re-encrypt)". The epic's own prose for Story 8 states 8a/8c/8d
"remain here as the functional AC reference; their realization happens via Story 13" — but the
epic's recommended build order still places 8c *before* 13a–13f, so this story ships a real,
standalone, production `Nebu.Workers.MediaArchiveWorker` now. Story 13c's later job is to
retire this worker's cron entry and fold its logic into the unified ladder — this story does
not need to anticipate that consolidation architecturally beyond keeping the copy mechanism
and `archived_at` semantics stable, since 13c is explicitly designed to reuse them unchanged.

## User Story

As the Nebu server operator, I want aged `:released` media objects automatically copied to a
cheaper, separately-configured archive bucket — without re-encrypting bytes and without
changing the file's lifecycle state — so that storage cost for rarely-accessed released media
drops over time while downloads keep working exactly as before.

## Acceptance Criteria

1. **AC1 — Config source.** `released_archive_after_days` (integer, default `nil` = disabled)
   and `archive_delete_from_primary` (boolean, default `false`) gate the worker. These are the
   same two knobs the epic's Story 8c bullet and ADR-030's rung table name for the `archive`
   rung. Until Story 9a's `media_config` table/`Nebu.Media.Config` module lands, both are read
   via `Application.get_env(:nebu, :media_archive, released_archive_after_days: nil,
   archive_delete_from_primary: false)` — a config seam, not a hardcoded literal, so 9a/9b can
   later swap the source without touching the worker's call sites (same pattern Story 2e uses
   for its own pre-9a config values). `released_archive_after_days: nil` makes the worker's
   query return zero rows and the job is a pure no-op — it must never raise or crash when
   archiving is disabled.
2. **AC2 — Eligibility is `state == 'released'` only, explicit allow-list.** The candidate
   query's sole state filter is `WHERE state = 'released'`. `:infected`, `:reserved`,
   `:quarantined`, `:scanning`, `:admin_blocked`, `:deleted`, and `:hard_deleted` files are
   never selected, regardless of age — including files that *used to be* `:released` and later
   transitioned away (e.g. an admin-blocked file that was archived first, then blocked; its
   `archived_at` from the earlier archive run is left untouched, but no *new* archive run may
   touch it while `state != 'released'`).
3. **AC3 — Age threshold anchors on `uploaded_at`.** `media_files` has no dedicated
   "became-released-at" timestamp column (Story 1a's migration added `archived_at`,
   `deleted_at`, `hard_deleted_at` — deliberately not a `released_at`; adding one is a schema
   change and out of scope for this story, see Dev Agent Guardrails). The eligibility age is
   `uploaded_at < NOW() - (released_archive_after_days || ' days')::interval`. This is a
   deliberate simplification versus deriving the exact release timestamp from
   `media_state_transitions` — acceptable because the vast majority of `:released` files
   transition out of quarantine within minutes of upload (Story 4b's scan turnaround), so
   `uploaded_at` and "time since release" differ by a scan-duration-sized margin, not a
   retention-threshold-sized one.
4. **AC4 — Already-archived rows are excluded.** `archived_at IS NULL` is part of the
   candidate filter — a row that already has `archived_at` set is never re-selected by a later
   run, which is also the mechanism that makes the job idempotent (AC8).
5. **AC5 — Storage mechanism: server-side bucket-to-bucket copy, no re-encrypt.**
   `Nebu.Media.Storage` gains a function that wraps `ExAws.S3.put_object_copy/5`, copying the
   object from the primary bucket to the Story-11b-configured archive bucket **under the same
   object key** (`row.storage_key`). No bytes are ever pulled into the worker process, decrypted,
   or re-uploaded — this is exactly the mechanism the epic's Story 8c bullet mandates ("nur
   serverseitige S3-Copy, kein Download/Entschlüsseln/Wieder-Verschlüsseln").
6. **AC6 — `storage_key` is unchanged; only bucket resolution changes.** Per ADR-029, the
   object key is computed once at upload time and is never recomputed on read. Archiving does
   **not** write a new `storage_key` — the same key now simply also (or exclusively, if
   `archive_delete_from_primary`) exists in the archive bucket. The only thing that must change
   to keep downloads working is *which bucket* a reader consults, driven by `archived_at`
   being set or not — not the key value itself.
7. **AC7 — Copy-then-verify-then-commit ordering (ADR-032).** The worker never sets
   `archived_at` before the S3 copy has been confirmed to succeed. Sequence per row, matching
   ADR-032's normative ordering for every delete/archive-family story in this epic:
   1. `ExAws.S3.put_object_copy/5` against the archive bucket; a non-`{:ok, _}` result aborts
      this row (Oban retries the job; no DB write happens for this row on this attempt).
   2. Only after the copy succeeds: `UPDATE media_files SET archived_at = NOW() WHERE media_id
      = $1 AND state = 'released' AND archived_at IS NULL` (the `WHERE ... archived_at IS NULL`
      clause is also this story's idempotency guard, see AC8).
   3. Only if that `UPDATE` actually affected a row (this execution "won") **and**
      `archive_delete_from_primary` is `true`: delete the primary-bucket object. A losing
      concurrent execution (0 rows affected) never reaches this step.
   Never delete the primary object before `archived_at` is durably committed — that would
   create the "S3 blob gone, DB row doesn't know it" failure mode ADR-032 explicitly rejects.
8. **AC8 — Idempotent under repeated and concurrent runs.** Running the job twice in a row, or
   two overlapping executions racing on the same row, must not error, must not double-copy in a
   way that corrupts state, and must not double-fire the audit entry or the primary-delete
   step. The `archived_at IS NULL` filter in both the candidate query and the commit `UPDATE`
   is what makes a second/concurrent attempt on an already-archived row a safe no-op (0 rows
   affected, no audit entry emitted, no primary delete attempted).
9. **AC9 — Audit entry on the archive action, no `media_state_transitions` row.** A successful
   archive (i.e., the commit `UPDATE` in AC7 step 2 actually affected a row) writes exactly one
   `Nebu.Compliance.AuditWriter.log/6` entry with action `"media_archived"` — the epic's own
   text for this story: "Übergang schreibt `media_archived` in den globalen Audit-Log". This is
   **not** a `media_state_transitions` insert and **not** a `Nebu.Media.StateMachine.transition/3`
   call — `state` never changes (ADR-029: "No new state for archival"), so there is no
   lifecycle transition to log; only the global compliance audit log records the event.
   `"media_archived"` must be added to `Nebu.Compliance.AuditWriter`'s `@known_actions`
   allowlist in the same change — merging an audit action without updating that list is a
   documented recurring gotcha in this project (it silently breaks the audit trail:
   `AuditWriter.log/6` rejects unknown actions with `{:error, :audit_unknown_action}`).
10. **AC10 — Shared cron cadence with Story 8a.** `Nebu.Workers.MediaArchiveWorker` runs on the
    same `02:00 UTC` daily `Oban.Plugins.Cron` cadence as Story 8a's `MediaCleanupWorker`, per
    the epic's own text ("Archiv-Copy und Retention-Hard-Delete teilen sich den
    Cron-Rhythmus"). The two jobs operate on disjoint candidate populations (8a:
    `state IN ('deleted', 'infected')`; 8c: `state = 'released' AND archived_at IS NULL`), so
    running at the same cron tick creates no row-level contention between them.
11. **AC11 — Download-gate bucket switch (extends Story 1c).** `server/lib/nebu/media.ex`'s
    `fetch_and_decrypt/3` is extended to resolve the object from the archive bucket when
    `row.archived_at` is set, and from the primary bucket otherwise — the exact rule the epic
    states for the download handler ("prüft `archived_at`: gesetzt → Archiv-Bucket, sonst
    primärer Bucket"). `Nebu.Media.DB.lookup/2`'s `@sql_lookup`/`to_map/1` must additionally
    select and expose `archived_at` on the row (Story 1c only added `state`; `archived_at` was
    not part of that story's scope and must be added here, coordinated with whichever of 1c/8c
    lands second so the `SELECT` list ends up including both).

## Acceptance Tests

New file `server/test/nebu/workers/media_archive_worker_test.exs`, using `Oban.Testing`
(`use Oban.Testing, repo: Nebu.Repo`) and unit-testing `perform/1` directly against injectable
`FakeRepo`/`FakeStorage`/`FakeAuditWriter` doubles (matching the fake-collaborator style already
used by `media_scan_worker_test.exs`/`media_reserved_upload_cleanup_worker_test.exs`, not a full
DB sandbox):

1. `test "eligible :released files older than the threshold with archived_at IS NULL are copied to the archive bucket and archived_at is set"` — `FakeRepo` returns one or more candidate rows; asserts `FakeStorage.put_object_copy/2`(or equivalent) was called with the row's `storage_key` and the configured archive bucket, and that the commit `UPDATE ... archived_at = NOW()` was issued for each row.
2. `test "files in any non-:released state are never selected, regardless of age"` — parametrized over `[:infected, :reserved, :quarantined, :scanning, :admin_blocked, :deleted, :hard_deleted]`; `FakeRepo`'s candidate query is asserted to filter on `state = 'released'` only (or, at the fake-repo level, simulated to return zero rows for non-released fixtures) and `FakeStorage.put_object_copy/2` is never invoked for these fixtures.
3. `test "a :released file with archived_at already set is not re-copied"` — candidate query excludes it (fake simulates the `archived_at IS NULL` filter); `FakeStorage.put_object_copy/2` not called.
4. `test "released_archive_after_days = nil disables the worker entirely"` — config seam returns `nil`; `perform_job/2` returns `:ok`; the candidate query is never issued (or returns immediately without executing); no storage calls, no audit calls.
5. `test "storage_key is unchanged after archiving; only archived_at changes"` — asserts the commit `UPDATE`'s SQL/params never touch `storage_key`, and the row's `storage_key` before/after the worker run is identical.
6. `test "downloads still work after archiving"` — integration-style test against the download handler (mirrors `media_download_gate_test.exs`'s fixture conventions): seed a `media_row/1` with `state: :released, archived_at: ~U[...]`; inject a `FakeStorage` whose `get/1` (primary bucket) flunks/raises if called, and whose archive-bucket accessor returns the plaintext bytes; assert `GET /_matrix/media/v3/download/...` still returns `200` with the original decrypted bytes, proving `fetch_and_decrypt/3`'s bucket switch (AC11) actually routes to the archive bucket and never touches the primary one.
7. `test "downloads for a non-archived :released file still use the primary bucket"` — same fixture with `archived_at: nil`; the archive-bucket accessor flunks/raises if called; primary `get/1` returns the bytes; regression guard that AC11's new branch didn't invert the default case.
8. `test "the copy-then-commit ordering never sets archived_at when the S3 copy fails"` — `FakeStorage.put_object_copy/2` returns `{:error, :some_s3_error}`; asserts no commit `UPDATE` was issued and the job returns `{:error, _}` (Oban retries), matching ADR-032.
9. `test "archive_delete_from_primary: true deletes the primary object only after archived_at is committed"` — asserts the call order: `put_object_copy` → commit `UPDATE` → primary `delete`, never `delete` before the `UPDATE`.
10. `test "archive_delete_from_primary: false (default) leaves the primary object in place"` — asserts no primary-bucket delete call is made at all.
11. `test "the job is idempotent under repeated runs"` — first `perform_job/2` call archives a row and the fake is updated so the row no longer matches the `archived_at IS NULL` candidate filter; a second `perform_job/2` call results in zero additional `put_object_copy`/commit/audit/delete calls.
12. `test "the job is idempotent when two executions race on the same row"` — simulate a concurrent second attempt whose commit `UPDATE` affects 0 rows (another execution already committed `archived_at`); assert no audit entry is emitted and, if `archive_delete_from_primary: true`, no primary delete is attempted by the losing execution.
13. `test "a successful archive writes exactly one media_archived audit entry via Nebu.Compliance.AuditWriter"` — asserts `FakeAuditWriter.log/6` (or the injected audit seam) was called once with action `"media_archived"`, target type/id identifying the media file, and metadata that includes the archive bucket used.
14. `test "no media_state_transitions row / StateMachine.transition call is issued for an archive action"` — asserts the injected `FakeStateMachine.transition/3` double (if present in the shared media fakes) is never called by this worker, distinguishing this story from 8a/2e/4b's state-transition-driven workers.
15. `test "media_archived is present in Nebu.Compliance.AuditWriter's known-action allowlist"` — a small regression test alongside the existing `AuditWriter` test suite (or inline here) asserting `AuditWriter.log(..., "media_archived", ...)` does not return `{:error, :audit_unknown_action}`.

## Technical Requirements

Follows ADR-018 (inline SQL, no repository/domain layer), ADR-025 (Oban), ADR-029
(storage-key immutability, no new archival state), and ADR-032 (copy-then-verify-then-commit
ordering).

### Worker module

`server/lib/nebu/workers/media_archive_worker.ex`:

```elixir
defmodule Nebu.Workers.MediaArchiveWorker do
  use Oban.Worker, queue: :media_cleanup, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case archive_after_days() do
      nil -> :ok
      days -> archive_candidates(days) |> Enum.each(&archive_one/1)
    end

    :ok
  end

  defp archive_one(%{media_id: media_id, storage_key: storage_key}) do
    case storage().put_object_copy(storage_key, archive_bucket()) do
      :ok ->
        case db().commit_archived(media_id) do
          {:ok, :committed} ->
            audit_writer().log(
              "system:media_archive_worker",
              "media_archived",
              "media_file",
              media_id,
              %{archive_bucket: archive_bucket(), archive_delete_from_primary: delete_from_primary?()},
              "success"
            )

            if delete_from_primary?(), do: storage().delete(storage_key)

          {:ok, :already_archived} ->
            :ok  # lost the race — no-op, no audit, no delete
        end

      {:error, _reason} = error ->
        error  # Oban retries; archived_at is never touched on a failed copy
    end
  end

  defp archive_after_days, do: config()[:released_archive_after_days]
  defp delete_from_primary?, do: config()[:archive_delete_from_primary] || false
  defp archive_bucket, do: storage().archive_bucket()

  defp config, do: Application.get_env(:nebu, :media_archive, released_archive_after_days: nil, archive_delete_from_primary: false)
  defp archive_candidates(days), do: db().candidates_for_archive(days)

  defp state_machine, do: Application.get_env(:nebu_http, :media_state_machine_module, Nebu.Media.StateMachine)
  defp db, do: Application.get_env(:nebu_http, :media_db_module, Nebu.Media.DB)
  defp storage, do: Application.get_env(:nebu_http, :media_storage_module, Nebu.Media.Storage)
  defp audit_writer, do: Application.get_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)
end
```

(Illustrative — adapt naming to whatever exact seam names `Nebu.Media.DB`/`Nebu.Media.Storage`
already use in the codebase at the time this story is implemented; the load-bearing points are
the copy-then-commit-then-optionally-delete order, the `archived_at IS NULL`-guarded commit as
the sole idempotency/race mechanism, and the audit call gated on actually having won that race.
`state_machine/0` is listed only to make explicit that this worker does **not** call it — no
`Nebu.Media.StateMachine.transition/3` invocation belongs in this file, see AC9.)

### Candidate query (inline SQL, ADR-018)

```sql
SELECT media_id, storage_key
  FROM media_files
 WHERE state = 'released'
   AND archived_at IS NULL
   AND storage_key IS NOT NULL
   AND uploaded_at < NOW() - ($1 || ' days')::interval
 LIMIT 500
```

(`LIMIT` bound matches the existing pattern in `Nebu.Compliance.SessionExpiryWorker`'s scan
query and Story 2e's cleanup query — a single tick cannot unboundedly scan the table.)

### Commit UPDATE (the idempotency/race guard, AC7/AC8)

```sql
UPDATE media_files
   SET archived_at = NOW()
 WHERE media_id = $1
   AND state = 'released'
   AND archived_at IS NULL
```

A `RETURNING media_id` (or checking `num_rows` on the result) is how the worker distinguishes
"this execution committed the archive" (audit + optional primary delete) from "another
execution already did" (silent no-op).

### `Nebu.Media.Storage` extensions

- `archive_bucket/0` — new config accessor, `Application.get_env(:nebu_http, :media_archive_bucket, ...)`, mirroring the existing `bucket/0` private helper but reading the Story-11b-configured archive bucket name instead of the primary one.
- `put_object_copy/2` (or similarly named) — wraps `ExAws.S3.put_object_copy(archive_bucket(), key, bucket(), key) |> ExAws.request()`, returning `:ok` / `{:error, reason}` matching the existing `get/1`/`put/2` return shape.
- `delete/1` — new, wraps `ExAws.S3.delete_object(bucket(), key) |> ExAws.request()`; used only by the `archive_delete_from_primary: true` path. (Does not exist in `Nebu.Media.Storage` today — `get/1`/`put/2` are the only functions currently defined.)
- The existing `get/1`/`put/2` **must remain unchanged** in signature and default-bucket behavior — every other caller (upload path, Story 4b's scan worker, Story 8a's cleanup worker) keeps calling them exactly as today; this story only **adds** functions, it does not change `get/1`'s bucket resolution.

### Download-path bucket switch (`server/lib/nebu/media.ex`, extends Story 1c)

`fetch_and_decrypt/3` must pick the bucket based on `row.archived_at`:

```elixir
defp fetch_and_decrypt(conn, row, on_ok) do
  get_result =
    if row.archived_at do
      storage_module().get_from_archive(row.storage_key)
    else
      storage_module().get(row.storage_key)
    end

  with {:ok, ciphertext} <- get_result,
       # ... existing decrypt pipeline, unchanged ...
end
```

(Illustrative — the exact function name for the archive-bucket read is up to the dev agent;
`get_from_archive/1` calling `ExAws.S3.get_object(archive_bucket(), key)` is one reasonable
shape. The load-bearing requirement is: `row.archived_at` truthy → archive bucket; falsy →
primary bucket, with no third branch and no silent fallback that reads the wrong bucket.)

### `Nebu.Media.DB` — expose `archived_at` on the lookup row

`@sql_lookup`'s `SELECT` list and `to_map/1`'s parsing must include `archived_at` (Story 1c
already adds `state` to this same query — coordinate so both land in the final `SELECT` list
regardless of which story's pipeline run reaches this file first). A new `candidates_for_archive/1`
function (used by the worker's candidate query above) is a separate, additive function on the
same module — it does not replace or alter `lookup/2`.

### Cron registration

`server/config/config.exs`, added to the existing `Oban.Plugins.Cron` `crontab:` list
(alongside Story 8a's entry, same `"0 2 * * *"` schedule):

```elixir
{"0 2 * * *", Nebu.Workers.MediaArchiveWorker}
```

## File List

| File | Change Type | Notes |
|---|---|---|
| `server/lib/nebu/workers/media_archive_worker.ex` | NEW | The Oban worker — see Technical Requirements |
| `server/lib/nebu/media/storage.ex` | UPDATE | Add `archive_bucket/0`, `put_object_copy/2`, `delete/1`; `get/1`/`put/2` unchanged |
| `server/lib/nebu/media.ex` | UPDATE | `fetch_and_decrypt/3` picks primary vs. archive bucket based on `row.archived_at` (AC11) |
| `server/lib/nebu/media/db.ex` | UPDATE | Add `archived_at` to `@sql_lookup`/`to_map/1`; add `candidates_for_archive/1` and `commit_archived/1` |
| `server/lib/nebu/compliance/audit_writer.ex` | UPDATE | Add `"media_archived"` to `@known_actions` |
| `server/config/config.exs` | UPDATE | Add the `"0 2 * * *"` cron entry for `Nebu.Workers.MediaArchiveWorker` |
| `server/test/nebu/workers/media_archive_worker_test.exs` | NEW | Acceptance tests above |
| `server/test/nebu/media/media_download_gate_test.exs` (or a new sibling file) | UPDATE | Add the post-archive download regression tests (Acceptance Tests 6–7) |
| `server/test/nebu/media/media_test_support.exs` | UPDATE | Add an `:archived_at` option to `media_row/1`, default `nil` |
| `server/test/nebu/media/media_fakes.exs` | UPDATE (if needed) | Extend the storage fake with archive-bucket-aware doubles |

## Dev Agent Guardrails

**Do Not Change:**

- **Never archive a file in a non-`:released` state.** `state = 'released'` is the sole,
  explicit eligibility filter in the candidate query — do not implement this as "archive
  everything except a deny-list" (the same allow-list-not-deny-list principle Story 1c's
  `download_gate/1` enforces for the download path applies here to the archive-eligibility
  path).
- **Do not set `archived_at` before the S3 copy is confirmed successful** (ADR-032). A failed
  copy must leave the row completely untouched — no partial state, no `archived_at` set on a
  copy that didn't actually land.
- **Do not delete the primary-bucket object before `archived_at` is durably committed in
  Postgres**, even when `archive_delete_from_primary: true`. Deleting first and marking second
  is exactly the "S3 blob gone, DB doesn't know it" failure mode ADR-032 rejects.
- **Must not break download availability post-archive.** The download handler's bucket switch
  (AC11) is not optional polish — without it, every file this worker touches becomes a silent
  404/500 the moment it's archived, in production, for real users. Do not ship the worker
  without the corresponding `fetch_and_decrypt/3` change in the same story.
- **Retrieval-latency / cold-storage semantics are explicitly OUT OF SCOPE for this story —
  flag, don't build.** Neither the epic text, ADR-029, nor ADR-030 describe the archive bucket
  as a Glacier-style cold tier with asynchronous restore; it is a plain, always-warm
  S3-compatible bucket the operator configures in Story 11b. This story's download-path bucket
  switch therefore assumes synchronous, immediate read availability from the archive bucket —
  there is no "restore request" step, no polling, no delayed-availability handling anywhere in
  this design. If a future story introduces a genuinely cold archive tier (real retrieval
  latency), that changes the download-gate contract (AC11's simple if/else bucket pick would no
  longer be sufficient — a pending-restore state or a stall mechanism analogous to Story 2d
  would be needed) and must be raised as its own decision point against the epic/ADR-029,
  not quietly special-cased into this worker.
- **Do not add a `released_at` (or similarly named) column to `media_files`.** This story uses
  the existing `uploaded_at` column as the age anchor (AC3) precisely to avoid a schema change;
  `server/priv/migrations/` is pipeline-protected per `CLAUDE.md` and a new migration is not
  part of this story's scope.
- **Do not model archiving as a `Nebu.Media.StateMachine.transition/3` call or a
  `media_state_transitions` insert.** `state` never changes; only `archived_at` does. Reusing
  the state-machine/transitions machinery here would be modeling a storage-location change as a
  lifecycle change, which ADR-029 explicitly rejects ("No new state for archival").
- **Do not forget the `Nebu.Compliance.AuditWriter.@known_actions` update in the same change.**
  This project has previously broken the audit trail by merging a branch that writes a new
  audit action without registering it in the allowlist first — `"media_archived"` must land in
  `@known_actions` in the same commit as the worker that emits it, not as a follow-up.
- **Do not recompute or rewrite `storage_key`.** Per ADR-029 the key is immutable once assigned
  at upload time — archiving changes only which bucket a given key is read from, never the key
  itself.
- **`legal_hold` (Story 13a/13e) does not exist as a column at the time this story is normally
  built** (this story's own dependency list is 1a/8a/11b/1c, not 13a). Do not invent a
  `legal_hold` check speculatively. If `media_files.legal_hold` already exists by the time this
  story is actually implemented (e.g. because Story 13 landed first in a different build order),
  add `AND legal_hold = false` (or the equivalent) to the candidate query as a defensive
  addition — but do not block this story's own completion on Story 13 landing first.
- Do not touch `Nebu.Media.Storage.get/1`'s or `put/2`'s existing bucket-resolution behavior —
  every other caller (upload path, Story 4b's scan worker, Story 8a's cleanup worker) must keep
  working unmodified against the primary bucket.
- This worker and its migration-adjacent DB changes live partly under
  `server/lib/nebu/`/`server/test/nebu/`, which is pipeline-protected per `CLAUDE.md`. Do not
  hand-apply changes outside an active `nebu-pipeline` run.

## Dependencies

- **1a-media-files-migration** — provides the `archived_at` and `storage_key` columns on
  `media_files` this story reads and writes.
- **1c-download-gate-enforcement** — this story's download-path bucket switch (AC11) extends
  `fetch_and_decrypt/3`, which 1c introduces the surrounding state-gate for; the two must remain
  compatible (the state gate runs first — `:released` only — and only then does the archive
  bucket switch decide *which* bucket to read from).
- **8a-media-cleanup-worker** — shares the `:media_cleanup` Oban queue and the `02:00 UTC` cron
  slot (AC10); also the first story in this epic's `8*` split to establish the
  copy/delete-family ordering convention (ADR-032) this story follows.
- **11b (Object Storage Target Config — Storage-UI + Test Connection)** — must supply the
  archive-bucket configuration this worker and the download-path bucket switch both read via
  `Nebu.Media.Storage.archive_bucket/0`. If 11b has not landed by the time this story is
  implemented, `archive_bucket/0` falls back to a static `config.exs`/env value as a placeholder,
  with a `TODO` pointing at 11b for the eventual DB-backed, admin-configurable source.
- Enables downstream: **Story 13c** (`MediaLifecycleWorker`) is documented as reusing this
  story's exact copy mechanism and `archived_at` semantics when it later consolidates 8a/8c/8d
  into one engine — this story is the reference implementation Story 13c's own spec points back
  to, not a throwaway.

## Dev Agent Record

Implemented as specified, with three self-corrected deviations from this story's own
illustrative text (none expand scope beyond what AC11/Technical Requirements already mandated
touching):

1. **`Nebu.Media.DB.lookup/2`'s `to_map/1` used to hardcode `storage_key: media_id`** instead
   of reading the real, already-persisted column — a pre-existing bug, silently harmless only
   under the default `s3_key_prefix_template`, dormant since Story 11c introduced non-default
   templates. Fixed in the same change that adds `archived_at` to this exact SELECT list.
2. **The candidate/threshold SQL binds an already-resolved millisecond-epoch integer** directly
   against `uploaded_at` (`Nebu.Media.DB.candidates_for_archive/1`), not this story's own
   illustrative `uploaded_at < NOW() - ($1 || ' days')::interval` — confirmed empirically that
   the latter cannot type-check against the live schema (`uploaded_at` is `BIGINT`
   millisecond-epoch, not `TIMESTAMPTZ`). Mirrors Story 2e's own `now_ms - ttl_ms` convention.
3. **The worker uses `Enum.reduce_while/3`** (Story 2e's halt-on-real-error convention), not
   `Enum.each/2` + per-row `rescue` (Story 8a's convention), so a failed S3 copy or DB commit
   propagates `{:error, reason}` out of `perform/1` for Oban to retry the job — required by this
   story's own Acceptance Test 8.
4. **DB access for the worker goes through `Nebu.Media.DB`** (`candidates_for_archive/1`,
   `commit_archived/1`) via the existing `:media_db_module` seam, matching Story 4b's
   (`MediaScanWorker`) precedent and this story's own Technical Requirements — not a dedicated
   repo seam like Stories 8a/2e's own workers use.
5. `Nebu.Media.Storage.delete/1` already existed (added by Story 8a) — reused unchanged, not
   re-added.

Kassandra's security review (2026-07-19) found one additional real gap during the review
itself — `archive_one/1`'s `case` on `commit_archived/1` had no clause for that function's own
documented `{:error, reason}` return — fixed with an explicit propagating clause + a new
regression test before the review report was finished. APPROVED, 0 CRIT/HIGH/MED/LOW, 2 INFO.

Verified against a live stack: `make redeploy` clean (Oban cron entry validated at boot); unit
suite 1906 passed/0 failed (elixir 1.20, `--warnings-as-errors`); integration suite 2487
tests/27 failures/3 skipped (elixir 1.19, fresh Postgres+MinIO) — all failures pre-existing/
unrelated (documented baseline categories across this epic, 0 media/archive failures).
