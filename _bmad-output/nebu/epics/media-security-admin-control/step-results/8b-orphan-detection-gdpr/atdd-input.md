## Summary

**Scope correction (read this first).** The epic's original framing of Story 8b claimed it
"solves DSGVO Art. 17 (Right to Erasure)" by soft-deleting orphaned media. The epic's own
**Review 5** (2026-07-02, R-015) retracted that claim as **wrong**: Art. 17 for Nebu's target
market (deutsche Kommunen/Behörden) is not a naïve delete — it is **Restriction-of-Processing
(Art. 18) + Vier-Augen-Freigabe (two-eyes/dual-control approval)**, correctly modelled in
**Story 13e** (part of the new consolidated **Media Lifecycle Policy**, ADR-030). Story 13 (13a–13f)
is **not built in this epic pass** — it is tracked follow-up debt, deferred to a future epic.

**This story (8b) therefore does exactly one thing: it detects and reports orphan candidates.**
It is a read-only query/cron that identifies `media_files` rows no longer referenced by any
Matrix room event and surfaces them (audit log entry + structured log, admin-visible via the
existing `/audit-log` viewer). It does **not**:

- automatically delete or hard-delete anything,
- transition any `media_files.state` (no `:quarantined → :deleted` side effect lives here — see
  Acceptance Criteria #5, an explicit negative AC),
- implement, claim, or document itself as satisfying DSGVO Art. 17 in any way.

Any future consumption of this story's detection output (e.g. feeding candidates into the
Media Lifecycle Policy's `orphan_mark_after_hours` cohort rule, per ADR-030 §1) is **out of
scope here** — that consumption logic belongs to the Lifecycle Engine (Story 13c), which does
not exist yet. A dev agent picking up this story must build **detection and reporting only**,
not the transition that a differently-scoped read of the epic's Story 8 prose might suggest.

## User Story

As the Nebu server operator, I want a recurring job that identifies media files sitting in
`:quarantined` state that no room event references any longer, and reports them as orphan
candidates, so that I have visibility into unreferenced quarantined uploads accumulating in
storage — without the system ever autonomously deciding to delete them on my behalf.

## Acceptance Criteria

1. **Detection query (anti-join).** A query identifies every `media_files` row where:
   - `state = 'quarantined'`, and
   - `uploaded_at` is older than the configured `orphaned_hours` threshold (default 48), and
   - no `events.content` row references the file's `mxc://` URI
     (`mxc://<server_name>/<media_id>`, built at query time — `media_files` has no stored
     `mxc_uri`/`content_uri` column; see `server/lib/nebu/media.ex:96` for the existing
     construction pattern) in any of its plaintext-reachable fields: `content.url`,
     `content.avatar_url`, `content.info.thumbnail_url`.
   - **Known, documented gap (not a defect to silently fix here):** this query does **not**
     check the two encrypted-attachment fields `content.file.url` /
     `content.info.thumbnail_file.url` that ADR-030 identifies as part of the full 6-field
     mxc→room index. Building that full index is explicitly assigned to the Lifecycle Engine
     (Story 13, ADR-030 §1, "Room/space resolution mechanics") and is out of scope for this S-sized
     story. Because this story is **detection-only** (AC5), this gap cannot cause an unreviewed
     deletion — a human reviews the candidate report (via the audit log) before any action is
     taken on a flagged file. This is the load-bearing safety argument for keeping this story
     detection-only rather than auto-transitioning, see AC5.
2. **Recurring job, admin-visible report.** `Nebu.Workers.MediaOrphanDetectionWorker` runs on an
   `Oban.Plugins.Cron` schedule (hourly — `"0 * * * *"` — tighter than the daily 02:00 UTC
   `MediaCleanupWorker` cadence from Story 8a is not required here since nothing destructive
   happens; hourly keeps the report reasonably fresh without adding load). Each run writes
   **one** `Nebu.Compliance.AuditWriter.log/6` entry (action `media_orphan_detection_run`,
   `actor_type` semantics: `actor_user_id: nil` for a system-initiated run) with metadata
   `%{"candidate_count" => N, "candidate_media_ids" => [...]}` (list capped, see Technical
   Requirements) — **one audit entry per run, not one per candidate** (matches the epic's own
   "one decision, N-fold auditable" cohort principle from Story 6d, applied here to reporting
   rather than action). The entry is visible in the existing admin audit log viewer
   (`Nebu.Admin.AuditLogLive`, route `/audit-log`) — no new admin UI page is built by this
   story (`ui: false`).
3. **No `media_files` mutation of any kind.** The job issues only `SELECT` statements. It does
   not call `Nebu.Media.StateMachine.transition/3`, does not set `deleted_at`, does not touch
   `legal_hold` (that column does not exist yet — it belongs to ADR-030/Story 13). Orphan
   candidates remain in `:quarantined` state, fully functional/downloadable-per-scan-state,
   after every run.
4. **Config: `orphaned_hours`.** Default 48, sourced the same way Story 2e's TTL is sourced
   until `Nebu.Media.Config` (Story 9a) lands: a static `config.exs` value under the same key
   name the epic's `media_config` list already reserves for it (`orphaned_hours`), so Story 9a's
   later migration can absorb it without a rename.
5. **Explicit negative AC — does NOT implement Art. 17 / Restriction-of-Processing.** This story
   does not add an erasure-request endpoint, does not add `legal_hold`/`erasure_requested_at`
   columns, does not perform any state transition in response to detection, and no code comment,
   log message, audit action name, or (if any UI text exists elsewhere referencing this feature)
   copy anywhere in this story's deliverables may claim "GDPR"/"DSGVO Art. 17" compliance. The
   audit action name is deliberately `media_orphan_detection_run` (housekeeping-flavoured), not
   anything implying erasure or compliance fulfilment.
6. **Query is bounded and safe against the size of `events`.** The anti-join is `LIMIT`-bounded
   per run (see Technical Requirements) and Offene Entscheidung #3 ("Explain-Plan prüfen, ggf.
   GIN-Index als eigene Migration") is checked before this story ships — if `EXPLAIN ANALYZE`
   against a representative `events` table shows a full sequential scan per run, a small
   follow-up migration adding a GIN index on `events.content` is in scope for this story (see
   Technical Requirements); if the existing indexes are sufficient, no new index is added and
   this AC is satisfied by recording the explain-plan finding in the Dev Agent Record.

## Acceptance Tests

Following the `FakeRepo`/injectable-collaborator worker-test style already used in this epic
(see `server/test/nebu/compliance/session_expiry_worker_test.exs` and the planned
`server/test/nebu/workers/media_reserved_upload_cleanup_worker_test.exs`), using
`Oban.Testing` (`use Oban.Testing, repo: Nebu.Repo`):

1. **`test "identifies an unreferenced :quarantined media_files row older than orphaned_hours as an orphan candidate"`**
   — `FakeRepo` returns a `media_files` row with `state: "quarantined"`, `uploaded_at` older
   than the 48h threshold, and the anti-join sub-query result simulated as "no matching event";
   `perform_job(MediaOrphanDetectionWorker, %{})` returns `:ok`; assert the injected
   `FakeAuditWriter.log/6` double was called once with action `"media_orphan_detection_run"` and
   metadata containing that row's `media_id` in `candidate_media_ids`.
2. **`test "excludes media referenced via content.url from candidates (no false positive)"`** —
   `FakeRepo`'s anti-join simulation returns zero candidate rows for a `media_files` row whose
   constructed `mxc://` URI is present in a fake `events.content` match; assert the audit entry
   (if written at all, e.g. for a zero-candidate run) reports `candidate_count: 0` and that row's
   `media_id` never appears in `candidate_media_ids`.
3. **`test "excludes media referenced only via content.avatar_url or content.info.thumbnail_url from candidates"`**
   — same shape as test 2, covering the two additional plaintext-reachable fields from AC1.
4. **`test "excludes :quarantined rows younger than orphaned_hours even when unreferenced"`** —
   `FakeRepo` simulates a fresh, unreferenced `:quarantined` row inside the threshold window;
   asserts it is never selected as a candidate.
5. **`test "the job never calls Nebu.Media.StateMachine.transition/3"`** — the detection-only
   guarantee: inject a `FakeStateMachine` double, run `perform_job/2` against a fixture with one
   or more candidates, and assert `FakeStateMachine.transition/3` was called **zero** times
   regardless of how many candidates were found. This is this story's equivalent of the
   grep-invariant / "no raw UPDATE" test used elsewhere in the epic (Story 1b, Story 2e) — here
   the invariant is "no state transition at all, not even via the sanctioned StateMachine API."
6. **`test "writes exactly one audit_log entry per run, not one per candidate"`** — fixture with
   3+ candidate rows; assert `FakeAuditWriter.log/6` is called exactly once, with
   `candidate_count: 3` and all three `media_id`s present in the single entry's metadata list.
7. **`test "logs the run via Logger with route_template metadata for Trace-Map visibility"`** —
   asserts `Logger.metadata(route_template: "cron:media_orphan_detection", ...)` is set (or
   equivalent) before the summary `Logger.info/1` call, per the Review-9 "operational events via
   existing Logger calls" convention (Story 10e) rather than introducing a bespoke dashboard.
8. **`test "the job is idempotent under repeated runs (no duplicate/compounding side effects)"`**
   — running `perform_job/2` twice in a row against an unchanged fixture produces two
   independent audit entries with the same `candidate_count`/`candidate_media_ids` (not zero,
   not doubled) — because detection never mutates state, the same still-orphaned row is (by
   design) reported again on the next run until a human acts on it out-of-band.

## Technical Requirements

Per ADR-018 (inline SQL, no Repository/Service layer) and ADR-020 (`Nebu.Media` is the only
public-API surface for cross-domain calls from this worker).

- **Worker module:** `Nebu.Workers.MediaOrphanDetectionWorker`, in
  `server/lib/nebu/workers/media_orphan_detection_worker.ex`. `use Oban.Worker, queue:
  :media_cleanup, max_attempts: 3` (fewer attempts than mutation-performing workers — a failed
  detection run has no lasting effect and simply tries again next hour, no backoff drama
  needed).
- **Cron entry** in `server/config/config.exs`, alongside the epic's other `Oban.Plugins.Cron`
  entries:
  ```elixir
  {"0 * * * *", Nebu.Workers.MediaOrphanDetectionWorker}
  ```
- **Detection query** (verify `uploaded_at`'s actual column type against migration `000001`/
  `000022` before implementing — if it is `TIMESTAMPTZ` use direct comparison as below; if it
  turns out to be a ms-epoch `BIGINT` like `unused_expires_at` in Story 2a/2e, adjust the
  comparison accordingly):
  ```sql
  SELECT mf.media_id, mf.server_name, mf.uploaded_at
    FROM media_files mf
   WHERE mf.state = 'quarantined'
     AND mf.uploaded_at < NOW() - ($1 || ' hours')::interval  -- $1 = orphaned_hours
     AND NOT EXISTS (
           SELECT 1
             FROM events e
            WHERE e.content @> jsonb_build_object(
                    'url', 'mxc://' || mf.server_name || '/' || mf.media_id)
               OR e.content @> jsonb_build_object(
                    'avatar_url', 'mxc://' || mf.server_name || '/' || mf.media_id)
               OR e.content -> 'info' @> jsonb_build_object(
                    'thumbnail_url', 'mxc://' || mf.server_name || '/' || mf.media_id)
         )
   LIMIT 1000
  ```
  The `LIMIT 1000` bound matches the existing pattern in
  `Nebu.Compliance.SessionExpiryWorker`/Story 2e's cleanup query — a single tick cannot
  unboundedly scan `media_files`. If more than 1000 candidates exist, the excess is picked up on
  the next hourly run (detection-only, no urgency).
- **Offene Entscheidung #3 (GIN index).** Before this story ships, run `EXPLAIN ANALYZE` against
  a representative `events` table for the `NOT EXISTS` sub-query above. `events.content` has no
  GIN index today (only an expression index on `content->'m.relates_to'->>'event_id'` and a
  separate `tsvector` search-vector GIN index — see `server/priv/migrations/000001_init.up.sql`).
  If the explain plan shows a sequential scan of `events` per candidate row (likely, at scale),
  add a small follow-up migration:
  ```sql
  CREATE INDEX CONCURRENTLY IF NOT EXISTS events_content_gin_idx
    ON events USING GIN (content jsonb_path_ops);
  ```
  (own migration file, `CONCURRENTLY` to avoid locking the hot `events` table — cannot run
  inside the same migration transaction as other DDL, so it must be its own up/down pair if
  added). Record the explain-plan finding and the decision (index added or not) in this story's
  Dev Agent Record — this closes Offene Entscheidung #3 for the codebase, even though the
  decision itself was left open at epic-authoring time.
- **Audit action registration.** `media_orphan_detection_run` must be added to
  `Nebu.Compliance.AuditWriter`'s `@known_actions` list
  (`server/lib/nebu/compliance/audit_writer.ex`) — per the module's own doc comment ("Adding a
  new audit action requires updating this list first") and the project's known
  audit-allowlist-merge gotcha: skipping this makes `AuditWriter.log/6` return
  `{:error, :audit_unknown_action}` for every run, silently breaking the audit trail for this
  job specifically.
- **Structured logging for Trace-Map visibility.** Following the Review-9 / Story 10e
  convention ("operational events via existing `Logger` calls with `route_template` metadata,
  no bespoke pipeline visualization"), the worker sets `Logger.metadata(route_template:
  "cron:media_orphan_detection")` and logs a summary (`candidate_count`, run duration) via
  `Logger.info/1`, mirroring the pattern in `server/lib/nebu/web/plugs/request_logger.ex`.

## Dev Agent Guardrails

### Do Not Build

- **Do not implement automatic deletion, soft-delete, or any `media_files.state` transition for
  detected orphans.** That requires the two-eyes/lifecycle design (ADR-030, Story 13 —
  specifically the `orphan_mark_after_hours` cohort rule owned by the future Lifecycle Engine,
  Story 13c), which is **not built in this epic pass**. If Story 8a's `MediaCleanupWorker` looks
  like a tempting place to "just call it" from here — don't; 8a operates on `:deleted`/
  `:infected` rows already marked for hard-delete, it has no mandate over `:quarantined` rows,
  and wiring this job's output into it would silently reintroduce the exact auto-delete
  Review 5 removed.
- **Do not claim, in code comments, log messages, audit action naming, or any UI copy, that this
  story implements or satisfies "GDPR"/"DSGVO Art. 17".** The audit action is
  `media_orphan_detection_run`, not e.g. `gdpr_deletion` (that action name already exists in
  `@known_actions` for a *different*, unrelated admin-driven flow — do not repurpose it here and
  do not introduce a new action name that implies erasure-request handling).
- **Do not add `legal_hold`, `erasure_requested_at`, or `erasure_requested_by` columns.** Those
  belong to ADR-030/Story 13 and are out of scope here.
- **Do not build the full 6-field mxc→room index** (the `content.file.url` /
  `content.info.thumbnail_file.url` encrypted-attachment cases, or room/space policy
  resolution). That is Story 13's "Room/space resolution mechanics" concern (ADR-030 §1). This
  story's 3-field plaintext check is a deliberately scoped, documented subset — see AC1.
- **Do not build an admin UI page for the orphan report.** `ui: false` in this story's
  frontmatter is intentional; the audit log entry via the existing `Nebu.Admin.AuditLogLive`
  viewer is the report surface for this story. A dedicated `/admin/media/orphans` view, if ever
  wanted, is separate future scope.

### Do Not Change

- `Nebu.Media.StateMachine`'s allowed-transitions guard table (Story 1b) — this story adds no
  new edges; it calls `transition/3` **zero times**.
- Story 8a's `MediaCleanupWorker` — no coupling is added from that worker into this one or vice
  versa in this story.
- This code lives under `server/lib/`/`server/test/`, which is pipeline-protected per
  `CLAUDE.md`. Do not hand-apply it outside an active `nebu-pipeline` run.
