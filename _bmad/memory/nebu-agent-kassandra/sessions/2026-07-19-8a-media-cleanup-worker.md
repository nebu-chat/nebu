# Session 2026-07-19 — Story 8a-media-cleanup-worker security review

Story: media-security-admin-control/8a-media-cleanup-worker (`security_review: required`).
Data-destruction daily Oban cron (hard-delete aged `:deleted`/`:infected` media rows).

## Verdict: no CRITICAL/HIGH. One MEDIUM (compliance/correctness), rest INFO.

## F-1 MEDIUM (compliance/data-retention, fail-silent) — the `:deleted` retention path is DEAD in production
`media_files.deleted_at` is NEVER populated by any code path in `lib/`. Confirmed:
- Column added by mig 000022 (TIMESTAMPTZ, nullable, NO default, NO trigger — the only 000022
  trigger is `media_state_transitions_immutable` on the ledger table, not media_files).
- Every path into `:deleted` goes through `StateMachine.transition/4` -> `@sql_update_state`
  = `UPDATE media_files SET state = $2` ONLY. Only the `:hard_deleted` branch uses
  `@sql_update_state_hard_deleted` (sets uploader_user_id=NULL + hard_deleted_at=now()).
  No `deleted_at` analogue for the `:deleted` branch.
- `Nebu.Media.admin_delete/2` (media.ex:775, producer of `:deleted` rows) calls transition + audit
  only — never stamps deleted_at. No other writer of media_files.deleted_at exists (grep lib/priv).
Consequence: worker `:deleted` candidate query `WHERE state='deleted' AND deleted_at < NOW()-interval`
matches ZERO rows forever (`NULL < x` never true). Admin-soft-deleted media NEVER hard-deleted; bytes
retained indefinitely; retention policy silently unenforced for half the story's scope. Fail-silent
(dead query = NO signal, unlike the S3-error path's per-row Logger.error).
`:infected` path UNAFFECTED — derives age from append-only ledger `MAX(inserted_at) WHERE
to_state='infected'`, which transition/4 DOES populate (now()).
WHY IT SURVIVED ALL GATES: ATDD FakeRepo seeds `deleted_at` DIRECTLY on the fake row and filters on
it — never exercises the real admin_delete->:deleted path that leaves deleted_at NULL. Cross-story
seam masked by a fake presupposing the very population the production code omits.
Direction: OVER-retain (safer than premature-delete) -> MEDIUM not HIGH; no exploit path.
FIX: stamp deleted_at at the transition-to-`:deleted` site (mirror hard_deleted_at), OR — cleaner and
consistent — derive `:deleted` age from ledger `MAX(inserted_at) WHERE to_state='deleted'` exactly like
the `:infected` query already does.

## Angles cleared (defended):
- Race admin-un-infects vs worker (angle 3): DEFENDED. transition/4 re-locks (`SELECT ... FOR UPDATE`),
  re-reads state authoritatively; admin :infected->:released between candidate SELECT and transition =>
  allowed?(:released,:hard_deleted)=false => {:invalid_transition} => no-op. No released-then-deleted race.
- Timestamp tampering (angle 1): DEFENDED. :infected age anchored to immutable ledger inserted_at
  (ADR-031 trigger, server now(), not caller-controllable). `($1||' days')::interval` = bound param from
  static config -> no SQLi.
- Config trust boundary (angle 7): DEFENDED. deleted_days/infected_days static config.exs only; no
  admin-mutable / HTTP path (grep admin/+config/ clean).
- Reaper blast radius (angle 4): OK TODAY (only this worker's own partials; 2e reserved cron leaves
  storage_key NULL). INFO watch-flag for Story 13c: a future :hard_deleted-with-storage_key producer
  would be silently purged (no age/attribution filter on the reaper query).
- Storage.delete/1 (angle 5): CORRECT. 404->:ok; all other errors->{:error,reason}, row left for next
  sweep. Systemic bad-creds => per-row Logger.error (signal via enhanced-logging store), no metric/alert.
- ADR-020/018 (angle 6): COMPLIANT. Public APIs only + own read SELECTs + non-state UPDATEs (4b/4c
  carve-out). `media_hard_deleted` IS in @known_actions (audit_writer.ex:107) — AC10 satisfied.

## INFO — audit-log durability (angle 2)
Worker IGNORES AuditWriter.log/6 return. Audit-write failure AFTER storage_key nulled => audit_log row
lost, no retry. BUT authoritative immutable record (media_state_transitions `-> hard_deleted` row) is
written atomically inside transition/4 and CANNOT be lost — only the denormalized global audit_log
projection can. Consistent with codebase best-effort audit posture; test 13 guards allowlist-drop. INFO.
