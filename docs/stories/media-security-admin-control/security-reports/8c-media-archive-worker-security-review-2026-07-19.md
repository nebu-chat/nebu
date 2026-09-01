# Security Review — 8c-media-archive-worker

**Reviewer:** Kassandra · **Date:** 2026-07-19 · **Epic:** media-security-admin-control

## Verdict: APPROVED — 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW, 2 INFO

## Scope

`Nebu.Workers.MediaArchiveWorker` (NEW) — daily cron that server-side-copies aged
`:released` `media_files` objects to a second S3/MinIO bucket and stamps
`archived_at`, plus the download-path bucket switch (`Nebu.Media.fetch_and_decrypt/3`,
AC11) and the `Nebu.Media.DB`/`Nebu.Media.Storage` additions that support it.

## Self-corrected pre-existing bugs — independently re-verified, both real

1. **`Nebu.Media.DB.lookup/2`'s `to_map/1` hardcoded `storage_key: media_id`
   instead of reading the real column.** Confirmed real by direct source
   inspection: the old `@sql_lookup` never selected `storage_key` at all — the
   value could not have come from anywhere but the hardcode. Confirmed
   consequential (not cosmetic) by tracing `Nebu.Media.StorageConfig.compute_key/2`
   (Story 11c) and its live call site in `media.ex`'s
   `encrypt_compress_and_store/5` — the ONLY function that writes
   `media_files.storage_key` on upload — which persists a template-derived key
   that is NOT `media_id` for any `s3_key_prefix_template` other than the
   default `"{media_id}"`. Story 11b/11c already ship the admin UI to configure
   a non-default template; the old code would have silently 404/502'd every
   download of any file uploaded under such a template, independent of whether
   the file is ever archived. Correctly fixed: the SELECT list and `to_map/1`
   now both carry the real column through, verified against the live schema
   (`storage_key TEXT` added by migration `000022`).
2. **The story's own illustrative candidate SQL cannot type-check.** Confirmed
   by reading `server/priv/migrations/000001_init.up.sql:298` directly:
   `media_files.uploaded_at` is declared `BIGINT NOT NULL`, and every writer
   (`Nebu.Media.StateMachine.create/1`, `create_quarantined/1`) binds
   `System.system_time(:millisecond)` to it — a millisecond epoch integer, not
   a Postgres timestamp. `uploaded_at < NOW() - ($1 || ' days')::interval`
   would fail to plan (type mismatch between `bigint` and the `interval`
   subtraction's `timestamptz` result). The fix — binding an
   already-resolved millisecond-epoch threshold directly against the `bigint`
   column — is the same pattern `Nebu.Workers.MediaReservedUploadCleanupWorker`
   (Story 2e) already uses successfully in production. Verified this is not
   merely theoretical: the full `mix test --include integration` run (fresh
   Postgres) passed with this exact query shape, confirming it actually plans
   and executes.

Neither self-correction expands scope beyond what AC11/the Technical
Requirements already mandated touching in these exact functions, and neither
touches a "Do Not Change" guardrail item.

## ADR-032 ordering / concurrency — verified sound

- The commit `UPDATE ... WHERE media_id = $1 AND state = 'released' AND
  archived_at IS NULL` is the sole race guard, and it is sufficient: Postgres
  re-evaluates an `UPDATE`'s `WHERE` clause against the just-committed row
  version when a second transaction's row-level lock wait resolves (standard
  READ COMMITTED semantics) — no `SELECT ... FOR UPDATE` is needed, and none is
  used. Two genuinely concurrent commit attempts against the same row
  therefore always resolve to exactly one winner (`{:ok, :committed}`, 1
  row affected) and any number of losers (`{:ok, :already_archived}`, 0 rows).
- A double `put_object_copy/2` (both racers copy before either commits) is
  harmless: the source object is immutable (ADR-029, `storage_key` never
  recomputed), so a repeated `PUT Object Copy` of the identical bytes under the
  identical destination key is a pure no-op in effect.
- Copy-then-commit-then-audit-then-optional-delete ordering is enforced in code
  (traced line by line, not just trusted from the moduledoc) and pinned by a
  dedicated ordering test (AT9) that asserts the actual call sequence via an
  interleaved event log, not just that all three eventually happened.
- **Found + independently confirmed fixed during this review:** the dev's own
  cycle-0 self-code-review had left `archive_one/1`'s inner `case
  db().commit_archived(media_id) do` without a clause for `{:error, reason}` —
  a real, reachable return value of the function it was matching on (Postgrex
  errors do not always raise; `Ecto.Adapters.SQL.query/3` returns `{:error,
  _}}` tuples for many failure classes). An unhandled case clause here would
  have crashed with `CaseClauseError` on a genuine DB failure mid-commit —
  functionally caught by Oban's own job-executor rescue (still retries), but a
  correctness gap nonetheless, and NOT properly documented as intentional. The
  dev fixed this in the same pass (before I could even finish drafting this
  report) by adding an explicit `{:error, _reason} = error -> error` clause
  that propagates identically to a copy failure — re-verified: no audit entry,
  no primary delete, and the full integration suite (2487 tests, fresh
  Postgres) still passes with a dedicated new regression test (test 8b)
  pinning exactly this path. Not re-flagged as an open finding since it is
  fixed and independently re-verified in this same session.

## Download-path bucket switch (AC11) — no bypass, no leak found

- `row.archived_at` is sourced exclusively from the DB row via
  `Nebu.Media.DB.lookup/2` — there is no request parameter, header, or
  user-controlled input anywhere on the download path that maps to this field.
  An attacker cannot force the archive-bucket branch (or the primary-bucket
  branch) for a file that hasn't/has actually been archived.
  `Nebu.Media.download_gate/1`'s state-based allow/deny gate (Story 1c) runs
  strictly BEFORE this switch and is completely unmodified by this story — a
  non-`:released` file never reaches `fetch_and_decrypt/3` at all, archived or
  not.
- Both branches of the `if row.archived_at do ... else ... end` feed into the
  exact SAME `with {:ok, ciphertext} <- get_result, ...` pipeline and the exact
  SAME `else` error-mapping clauses (`:not_found -> 404`, anything else `->
  502`) — there is no distinguishing status code, header, or body shape
  between a primary-bucket read and an archive-bucket read. No new side
  channel is introduced by this story.

## Partial-failure / data-loss analysis

- Copy fails → row untouched (verified: `archived_at` stays `nil`, no commit
  attempted) → next tick re-selects the same candidate, safe to retry
  indefinitely. No data loss, no double-storage risk (nothing was copied).
- Copy succeeds, commit fails (DB error) → the object now exists in BOTH
  buckets (primary untouched, archive has a copy) but `archived_at` is still
  `nil` → next tick's candidate query re-selects the row (its filter is on
  `archived_at IS NULL`, not on "have we ever copied it") and re-attempts the
  copy (idempotent, harmless) and the commit again. Worst case: a small,
  bounded amount of storage is duplicated across bucket during the retry
  window, resolving itself on the next successful attempt — not a
  correctness or availability issue, at most a transient/negligible cost
  concern, and not novel (Story 8a's own `MediaCleanupWorker` has an
  analogous "already copied/deleted, retry is idempotent" property for its own
  primary-delete step).
- Commit succeeds, then a crash before the audit write or the primary delete →
  `archived_at` is durably committed (downloads already correctly route to the
  archive bucket from this point on, AC11 is satisfied) but the audit entry
  might be missing and/or `archive_delete_from_primary: true`'s delete might
  not have run yet. The audit gap is a compliance/observability concern, not
  an availability or confidentiality one (the file remains fully servable
  either way) — and this exact "audit write is not transactionally coupled to
  the state change it describes" posture is the SAME accepted pattern every
  other admin-action/worker in this codebase already uses (`Nebu.Media.write_
  admin_audit/4`, `MediaScanWorker`'s own comment: "no transaction coupling
  with the state-machine write already committed"). Not a new risk this story
  introduces; consistent with established precedent, not re-flagged.
- No scenario found where a file becomes permanently inaccessible: the
  download path always has a valid bucket to read from at every point in the
  sequence (primary before commit, archive after — and primary again too,
  until/unless `archive_delete_from_primary` actually deletes it, which only
  ever runs strictly after the commit is durable).

## Audit trail

- `"media_archived"` correctly added to `AuditWriter.@known_actions` in the
  same change that emits it (this project's own documented recurring
  footgun) — confirmed via the dedicated allowlist regression test (test 15)
  AND by direct inspection of the allowlist itself.
- Audit metadata includes the archive bucket name and the
  `archive_delete_from_primary` flag in effect at archive time — sufficient
  for an operator to reconstruct what happened without needing to correlate
  against current (possibly since-changed) config.
- Confirmed (test 14, backed by a `FakeStateMachine` that `raises` if ever
  called, not merely un-asserted) that this worker never calls
  `Nebu.Media.StateMachine.transition/3` and therefore never writes a
  `media_state_transitions` row — correctly modeling that archiving is a
  storage-location change, not a lifecycle transition (ADR-029).

## SSRF / bucket-confusion

- No new attacker-reachable surface: this is a cron-triggered worker with no
  HTTP entry point of its own. `archive_bucket()` resolves from
  `Application.get_env/3` (operator config only — `NEBU_MINIO_ARCHIVE_BUCKET`
  env var or `config.exs`), never from a request. `storage_key` is the
  already-validated, already-persisted value computed at upload time by
  `Nebu.Media.StorageConfig.compute_key/2`, which Story 11c's own
  `check_no_path_escape/1` already gates against path-traversal — this story
  does not introduce a new place where an attacker-controlled string reaches
  an S3 key or bucket name. `put_object_copy/2`'s argument order was checked
  against `ExAws.S3.put_object_copy/5`'s real signature
  (`dest_bucket, dest_object, src_bucket, src_object`) — confirmed correct,
  not swapped.

## INFO (non-blocking, forward-looking)

1. **No rate limit / backpressure on the archive-copy loop itself** beyond the
   existing `LIMIT 500` per tick — acceptable, mirrors every other retention
   worker in this epic (8a/2e/8b), all bounded the same way, all previously
   accepted without a dedicated rate limit.
2. **`archive_bucket/0`'s config fallback (`"nebu-media-archive"`) is a static
   placeholder pending Story 11b's eventual DB-backed per-target config** —
   explicitly flagged as a TODO in the story itself and in the code comments;
   not a gap this story is expected to close, consistent with 8a/8b's own
   documented "not yet rewired to 9a" posture for their own config values.

## Verification performed

- Read the full diff directly (not summarized) for every file listed in
  Scope.
- Independently confirmed both self-corrected bugs against the live schema
  (`server/priv/migrations/000001_init.up.sql`) and the real call graph
  (`Nebu.Media.StorageConfig.compute_key/2` → `media.ex`'s
  `encrypt_compress_and_store/5`), not merely the dev's own written
  justification.
- Traced the ADR-032 ordering by reading `media_archive_worker.ex` line by
  line, not from its moduledoc's prose summary alone.
- Found the missing `{:error, reason}` case clause myself by reading
  `Nebu.Media.DB.commit_archived/1`'s own `@spec` against
  `archive_one/1`'s `case` — confirmed it was fixed and re-verified against a
  fresh `mix test --include integration` run (2487 tests, 27 failures, all
  pre-existing/documented, 0 new).

No CRITICAL/HIGH/MEDIUM/LOW findings remain. Approved for commit.
