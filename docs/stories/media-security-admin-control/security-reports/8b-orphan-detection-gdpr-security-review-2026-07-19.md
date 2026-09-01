# Security Review — 8b-orphan-detection-gdpr

**Reviewer:** Kassandra 🔐
**Date:** 2026-07-19
**Scope:** Full diff for story `8b-orphan-detection-gdpr` (media-security-admin-control epic)

## Verdict: APPROVED — 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW, 1 INFO

## Files reviewed

- `server/lib/nebu/workers/media_orphan_detection_worker.ex` (NEW)
- `server/lib/nebu/compliance/audit_writer.ex` (`@known_actions` +1)
- `server/config/config.exs` (cron entry + static `orphaned_hours` config)
- `server/priv/migrations/000031_events_content_gin_index.up.sql` / `.down.sql` (NEW)
- `server/test/nebu/workers/media_orphan_detection_worker_test.exs` (NEW)
- `server/test/nebu/release_test.exs`, `server/test/nebu/matrix/migrations_grant_test.exs` (extended)

## Checks performed

1. **Detection-only invariant, independently verified.** `grep -n "StateMachine\|transition("
   server/lib/nebu/workers/media_orphan_detection_worker.ex` returns exactly one hit — inside
   the moduledoc's own prose stating it never calls it. No alias, no `Application.get_env` seam
   for a state-machine module, no call site anywhere. The worker is architecturally incapable of
   mutating `media_files.state` — this is not merely a tested behavior, it is a structural
   property of the module (nothing in it can reach the state-machine API even by accident in a
   future edit that forgets to check a test).

2. **SQL injection surface.** The anti-join query has exactly one bound parameter (`$1`, a
   precomputed millisecond-epoch integer computed in Elixir and passed via Postgrex parameter
   binding — never string-interpolated into the query text). The `||` concatenations
   (`'mxc://' || mf.server_name || '/' || mf.media_id`) are literal SQL, evaluated per-row by
   Postgres against `mf.server_name`/`mf.media_id` — correlated COLUMN REFERENCES, not
   Elixir-side string interpolation of attacker-reachable input. This worker takes no request
   input at all (`perform_job(MediaOrphanDetectionWorker, %{})`, fixed hourly cron, empty args)
   — there is no injection vector, in principle or in practice.

3. **Audit trail integrity.** Verified `audit_log.actor_user_id` is a required, non-nullable
   changeset field (`AuditLogEntry.@required_fields`) — the story's own draft text ("nil for a
   system-initiated run") would have made `AuditWriter.log/6` return
   `{:error, :audit_unknown_action}`-adjacent validation failures for EVERY run, silently and
   permanently breaking this worker's entire compliance-visibility purpose. The shipped code
   correctly uses `"system:media_orphan_detection_worker"`, matching the established
   `"system:<worker_name>"` convention already used by every other system-initiated worker in
   this epic (`media_cleanup_worker.ex`, `media_scan_worker.ex`, `media/config.ex`,
   `media/storage_config.ex`, `compliance/session_expiry_worker.ex`). `media_orphan_detection_run`
   is present in `@known_actions` (verified: absent would silently no-op every run, the exact
   epic-recurring allowlist gotcha from Stories 4c/6a/9a). Confirmed via a dedicated regression
   test (`media_orphan_detection_worker_test.exs`, "is present in AuditWriter.@known_actions")
   that independently exercises the REAL `AuditWriter.log/6`, not just the test-double.

4. **No new attack surface.** No new admin endpoint, no new user-facing input path, no new
   column, no new data exposed beyond what already existed (`media_id`, `server_name`,
   `uploaded_at` — all pre-existing, already-readable-by-admins `media_files` columns). This is
   a pure backend cron job with zero external trigger surface.

5. **Scope-safety — no false compliance claim.** `git diff` grep for "Art. 17"/"GDPR" across the
   full diff shows every hit is either (a) the moduledoc explaining that an EARLIER draft's claim
   was retracted by the epic's own Review 5, or (b) an explicit "do not repurpose"/"do not claim"
   guardrail. No code comment, log message, or audit action name anywhere in this diff asserts or
   implies DSGVO/GDPR Art. 17 compliance. `media_orphan_detection_run` is distinct from the
   pre-existing, unrelated `gdpr_deletion` action — correctly not repurposed.

6. **Migration 000031 lock/availability impact (INFO, not a vulnerability).** `CREATE INDEX
   events_content_gin_idx ON events USING GIN (content jsonb_path_ops)` is a plain (not
   `CONCURRENTLY`) index build. Verified the stated reason is real, not a shortcut: `Nebu.Release
   .apply_migration/3` wraps every migration file's SQL in a single `Postgrex.transaction/2`
   unconditionally (`server/lib/nebu/release.ex`), and PostgreSQL forbids `CREATE INDEX
   CONCURRENTLY` inside a transaction block regardless of which file it's placed in — there is no
   way to get a non-blocking index build through this project's current migration runner. A plain
   `CREATE INDEX` takes a lock that blocks WRITES to `events` (not reads) for the build's
   duration — on a production instance with a large, actively-written `events` table, this could
   cause a visible pause in message-send throughput during the deploy window that applies this
   migration. This is an availability/operational consideration, not an exploitable security
   vulnerability (no attacker involved, one-time cost at deploy, consistent with every other
   migration in this codebase already having identical transactional-DDL lock characteristics).
   Rated **INFO**, not LOW — it is a pre-existing, project-wide migration-runner property (every
   prior migration already has this characteristic), not something newly introduced or worse than
   the established baseline. No fix required for this story; if `CREATE INDEX CONCURRENTLY`
   support is ever wanted project-wide, that is a `Nebu.Release`-level enhancement (add a
   non-transactional execution path for opt-in migration files), out of scope here.

7. **Sanctum cross-check (Story 8a's own recently-recorded pattern).** Checked this story against
   MEMORY.md's `media-security-admin-control (8a-media-cleanup-worker)` entry — "retention/cleanup
   worker keys off a timestamp column NOTHING populates in prod." `media_files.uploaded_at` (the
   column this worker's threshold check depends on) is a `NOT NULL BIGINT` column populated at
   row-creation time by every upload path (`Nebu.Media`'s upload/PUT handlers) — confirmed a real,
   always-populated writer exists, unlike 8a's dead `deleted_at`. This worker's query is not a
   repeat of that exact failure class.

## No CRITICAL/HIGH/MEDIUM/LOW findings

## Recommendation

Safe to proceed to arc42-update and commit.
