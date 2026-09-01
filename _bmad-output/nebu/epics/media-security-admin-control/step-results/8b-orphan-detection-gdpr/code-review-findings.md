# Code review — 8b-orphan-detection-gdpr (cycle 0)

## Verdict: CLEAN (0 MAJOR/CRITICAL, 0 MINOR)

## Files reviewed

- `server/lib/nebu/workers/media_orphan_detection_worker.ex` (NEW)
- `server/lib/nebu/compliance/audit_writer.ex` (allowlist +1)
- `server/config/config.exs` (cron entry + static `orphaned_hours` config)
- `server/priv/migrations/000031_events_content_gin_index.up.sql` / `.down.sql` (NEW)
- `server/test/nebu/workers/media_orphan_detection_worker_test.exs` (NEW, 9 tests)
- `server/test/nebu/release_test.exs`, `server/test/nebu/matrix/migrations_grant_test.exs` (extended for migration 31)

## Points specifically checked (adversarial pass)

1. **Threshold arithmetic.** `threshold_ms = System.system_time(:millisecond) -
   orphaned_hours() * 60 * 60 * 1000`. With the default 48, this is `48 * 3_600_000 =
   172_800_000` ms — correct. `mf.uploaded_at < threshold_ms` is a strict inequality,
   correctly implementing "older than" (a row uploaded exactly at the boundary is not yet a
   candidate). No off-by-one.

2. **`audit_writer().log/6` return value is not pattern-matched.** Confirmed this matches
   established precedent exactly — `Nebu.Workers.MediaCleanupWorker` (8a)'s own
   `audit_writer().log(...)` call is a bare statement, result discarded, relying on
   `AuditWriter`'s own internal `Logger.error` calls for operational visibility on failure
   (e.g. "AuditWriter: rejected unknown audit action" / "refused to write audit log"). Not a
   deviation introduced by this story; consistent with the whole worker fleet in this epic.
   Not flagged as a finding.

3. **`LIMIT 1000` behavior.** Matches the story's own documented intent exactly — excess
   candidates beyond 1000 are picked up on the next hourly run. No urgency, no data loss (a
   `:quarantined` row that's already an orphan stays one; it will be reported on a later run).

4. **Oban `max_attempts: 3` retry semantics.** The entire job is read-only `SELECT` + one
   append-only audit `INSERT` — a retry after a transient failure (e.g. a raised exception from
   `repo().query!/2` on connection loss) simply re-runs the whole detection from scratch. Even
   in the edge case where an audit insert commits and a subsequent unrelated crash still causes
   Oban to retry, the result is a second independent audit entry for the same still-orphaned
   data — which is explicitly the accepted, by-design behavior this story's own AT8 (idempotency
   test) already pins ("two independent audit entries... not zero, not doubled" refers to a
   single run's own candidate list never doubling, not a prohibition on multiple runs/retries
   each writing their own entry). No harmful duplicate *side effect* — there are no mutations to
   duplicate.

5. **Real-Postgres correctness of the 3-field exclusion, beyond the FakeRepo simulation.**
   Re-verified directly against a live Postgres instance (not just the ExUnit `FakeRepo`) with 4
   real `quarantined`/aged `media_files` rows — one genuinely orphaned, three each referenced via
   exactly one of `content.url`, `content.avatar_url`, and nested `content.info.thumbnail_url` —
   and the worker's EXACT final SQL. Result: only the genuinely orphaned row was returned; all
   three referenced rows were correctly excluded. Confirms the query's containment semantics are
   correct in production Postgres, not just in the unit-test fake.

6. **GIN index actually used, per real `EXPLAIN ANALYZE`.** Re-confirmed (see Dev Agent Record)
   that all 3 `NOT EXISTS` clauses use `Bitmap Index Scan` against
   `events_content_gin_idx`, not a `Seq Scan` — the story's AC6 performance concern is
   genuinely addressed, not just assumed.

7. **Detection-only invariant.** The worker never references `Nebu.Media.StateMachine` at all
   (not just "never calls it" — the module isn't imported/aliased/read from any seam), so the
   AT5 invariant holds at the source level, not only behaviorally.

8. **Migration safety.** `000031` is index-only (no new table), so no new `GRANT` is required
   (`events` already covered by migration 000001's blanket grant) — confirmed via
   `MigrationsGrantTest`'s own AC1 scope (table-creation only). Extended AC4's down-migration
   no-GRANT regression list for consistency with the existing convention that all recent
   migrations (000028–000030) are listed there regardless of table-creation status.

9. **`orphaned_hours` config seam.** Confirmed correctly independent from `Nebu.Media.Config`
   (Story 9a) — no accidental read of the DB-backed value, matching the documented, precedented
   design decision (8a's own `deleted_days`/`infected_days` divergence from `Nebu.Media.Config`'s
   own defaults for the same key names).

10. **Scope-safety / no false GDPR claim.** No code comment, log message, or audit action name
    anywhere in the diff claims or implies DSGVO/GDPR Art. 17 compliance. `media_orphan_detection_run`
    is distinct from the existing `gdpr_deletion` action, as required.

## No findings raised

No MAJOR, MINOR, or INFO findings. Proceeding to Step 7 (security review — `security_review:
required` per story frontmatter).
