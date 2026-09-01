## Session — 8b-orphan-detection-gdpr (media-security-admin-control epic)

**Scope:** Full diff — `Nebu.Workers.MediaOrphanDetectionWorker` (NEW, hourly detection-only
cron), `audit_writer.ex` allowlist +1, `config.exs` cron entry + static config, migration
000031 (`events_content_gin_idx`, GIN jsonb_path_ops), new worker test file, `release_test.exs`
+ `migrations_grant_test.exs` extensions.

**Finding summary:** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW, 1 INFO.

**INFO:** Migration 000031 uses a plain (non-`CONCURRENTLY`) `CREATE INDEX` on `events` —
verified the reason is a genuine, project-wide constraint (`Nebu.Release.apply_migration/3`
wraps every migration file in a `Postgrex.transaction/2` unconditionally; `CONCURRENTLY` is
forbidden inside a transaction, with no per-migration opt-out today). Not new risk — every
existing migration already has this same blocking-DDL characteristic. Not escalated; noted for
awareness only. If `CREATE INDEX CONCURRENTLY` support is ever wanted, that's a
`Nebu.Release`-level enhancement (a non-transactional execution path for opt-in migrations),
out of scope for any single story.

**New patterns discovered:** None rising to a MEMORY.md-worthy recurring pattern this session.
Cross-checked this story against the already-recorded 8a pattern ("retention/cleanup worker
keys off a timestamp column nothing populates in prod") — `media_files.uploaded_at` (this
worker's threshold column) IS a real, always-populated `NOT NULL` column written at every
upload path, confirmed not a repeat of that failure class.

**Accepted risks this session:** None new.

**Follow-up:** None. Report: `docs/stories/media-security-admin-control/security-reports/
8b-orphan-detection-gdpr-security-review-2026-07-19.md`.
