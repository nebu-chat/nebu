defmodule Nebu.Workers.MediaOrphanDetectionWorker do
  @moduledoc """
  Hourly Oban-cron DETECTION/REPORTING job
  (media-security-admin-control/8b-orphan-detection-gdpr) that identifies
  `media_files` rows sitting in `:quarantined` state, older than the
  configured `orphaned_hours` threshold, that no Matrix room event
  references any longer, and reports them as orphan candidates.

  ## Scope (load-bearing, read the story before touching this file)

  This worker is DETECTION-ONLY. It issues exclusively `SELECT` statements —
  it never calls `Nebu.Media.StateMachine.transition/3` (or `/4`), never sets
  `media_files.deleted_at`, and never mutates `media_files.state` in any way.
  An earlier draft of this epic (Story 8b) claimed this "solves DSGVO Art. 17
  (Right to Erasure)" by soft-deleting orphaned media — the epic's own
  Review 5 (2026-07-02, R-015) retracted that claim as wrong. Full Art. 17
  for Nebu's target market requires Restriction-of-Processing (Art. 18) +
  Vier-Augen-Freigabe, modelled in Story 13e (not built in this epic pass).
  This worker's ONLY job is to make orphan candidates visible via the audit
  log (`Nebu.Compliance.AuditWriter`) and structured `Logger` output, for a
  human operator to review and act on out-of-band. Do NOT wire this worker's
  output into `Nebu.Workers.MediaCleanupWorker` (Story 8a) or any other
  auto-delete path — that would silently reintroduce the exact auto-delete
  Review 5 removed.

  ## Detection query — anti-join, 3-field plaintext check

  A `media_files` row is an orphan candidate when:
    - `state = 'quarantined'`, and
    - `uploaded_at` (a BIGINT millisecond-epoch column — NOT `TIMESTAMPTZ`,
      confirmed against migration `000001_init.up.sql`) is older than
      `orphaned_hours`, and
    - no `events.content` row references the file's `mxc://<server_name>/
      <media_id>` URI (built at query time — there is no stored
      `mxc_uri`/`content_uri` column) via any of `content.url`,
      `content.avatar_url`, or `content.info.thumbnail_url`.

  Known, documented gap (not a defect to silently fix here): this query does
  NOT check the two encrypted-attachment fields `content.file.url` /
  `content.info.thumbnail_file.url` that ADR-030 identifies as part of the
  full 6-field mxc→room index. That full index is Story 13's "Room/space
  resolution mechanics" (ADR-030 §1), out of scope for this S-sized story.
  Because this worker is detection-only, this gap cannot cause an unreviewed
  deletion — a human reviews the candidate report before any action is taken.

  ## Query shape — 3 separate `NOT EXISTS` clauses, not one 3-way `OR`

  Empirically verified via `EXPLAIN ANALYZE` (see Dev Agent Record) that a
  SINGLE `NOT EXISTS` subquery with 3 OR-ed containment conditions produces a
  `Join Filter` the planner can NEVER push down to an index scan — even with
  the GIN index below present, and even with `enable_seqscan = off` forced,
  Postgres still chose a full `Seq Scan` on `events` (a `Join Filter` is a
  post-hoc filter evaluated after the join, not an indexable condition).
  Rewriting as 3 independent `NOT EXISTS` clauses ANDed together (De
  Morgan's equivalent of the original semantics: NOT (A OR B OR C) == NOT A
  AND NOT B AND NOT C) lets each individual containment check be pushed down
  as its own parameterized `Bitmap Index Scan` against the GIN index —
  confirmed via `EXPLAIN ANALYZE` showing `Index Cond` (not `Join Filter`)
  for all 3 checks, cutting execution time from ~1000ms to <1ms against a
  20,000-row representative `events` table.

  Separately, the `content.info.thumbnail_url` check is written as NESTED
  containment against the top-level `content` column
  (`content @> '{"info": {"thumbnail_url": "..."}}'`), not
  `content -> 'info' @> '{"thumbnail_url": "..."}'` — empirically verified
  that the `->` extraction form defeats the GIN index entirely (Postgres
  cannot push an index lookup through an extraction operator on the indexed
  column), while nested containment against the whole document uses the
  index directly (`jsonb_path_ops` GIN indexes support containment checks at
  any nesting depth).

  ## GIN index (AC6 / "Offene Entscheidung #3", closed by this story)

  `events.content` had no GIN index before this story (only an expression
  index on `content->'m.relates_to'->>'event_id'` and a separate `tsvector`
  search-vector GIN index — neither accelerates a general jsonb containment
  check). `EXPLAIN ANALYZE` against a representative `events` table
  confirmed a full sequential scan per run without a dedicated index; the
  follow-up migration `000031_events_content_gin_index` adds
  `CREATE INDEX events_content_gin_idx ON events USING GIN (content
  jsonb_path_ops)` (see that migration's own comment for why it is a plain,
  not `CONCURRENTLY`, `CREATE INDEX`).

  ## Config — `orphaned_hours`

  Read via `Application.get_env(:nebu, :media_orphan_detection, [])` with a
  `orphaned_hours: 48` fallback (`server/config/config.exs`) — the SAME
  pattern Story 8a's `MediaCleanupWorker` used for `deleted_days`/
  `infected_days` until story media-cleanup-reads-media-config rewired it
  to `Nebu.Media.Config.retention_days/0`. `Nebu.Media.Config` (Story 9a) already exists with its
  own DB-backed `orphaned_hours` key (default 24) — per 9a's own moduledoc
  ("This story only builds the table + module. It does NOT rewire any
  existing consumer... rewiring is each citing story's own follow-up work"),
  this worker deliberately does NOT read from `Nebu.Media.Config`, mirroring
  8a's former precedent of an intentionally-separate `config.exs` value
  (8a is rewired now; this worker is not yet).

  ## One audit entry per run, never one per candidate (AC2)

  A single `Nebu.Compliance.AuditWriter.log/6` call per run — regardless of
  whether 0 or up to 1000 (the `LIMIT`) candidates were found — with
  `actor_user_id: "system:media_orphan_detection_worker"` (the story's own
  "actor_user_id: nil for a system-initiated run" phrasing is corrected here:
  `actor_user_id` is a REQUIRED `audit_log` field, so `nil` would fail
  changeset validation and silently break the audit trail for every run —
  the established convention for every other system-initiated worker in
  this epic uses a `"system:<worker_name>"` string instead) and metadata
  `%{"candidate_count" => N, "candidate_media_ids" => [...]}`.

  ## Seams

  `Application.get_env(:nebu_http, :media_orphan_detection_repo_module,
  Nebu.Repo)` / `Application.get_env(:nebu_http, :media_audit_writer_module,
  Nebu.Compliance.AuditWriter)` — the SAME shared `:media_audit_writer_module`
  seam key `Nebu.Workers.MediaCleanupWorker` already reads, swappable
  independently for tests.
  """

  use Oban.Worker, queue: :media_cleanup, max_attempts: 3

  require Logger

  @audit_actor "system:media_orphan_detection_worker"

  # 3 separate NOT EXISTS clauses (not one 3-way OR) — see moduledoc "Query
  # shape" section for the empirically-verified reason. $1 is a precomputed
  # millisecond-epoch threshold (uploaded_at is BIGINT, not TIMESTAMPTZ).
  @sql_select_orphan_candidates """
  SELECT mf.media_id, mf.server_name, mf.uploaded_at
    FROM media_files mf
   WHERE mf.state = 'quarantined'
     AND mf.uploaded_at < $1
     AND NOT EXISTS (
           SELECT 1 FROM events e
            WHERE e.content @> jsonb_build_object(
                    'url', 'mxc://' || mf.server_name || '/' || mf.media_id)
         )
     AND NOT EXISTS (
           SELECT 1 FROM events e
            WHERE e.content @> jsonb_build_object(
                    'avatar_url', 'mxc://' || mf.server_name || '/' || mf.media_id)
         )
     AND NOT EXISTS (
           SELECT 1 FROM events e
            WHERE e.content @> jsonb_build_object(
                    'info', jsonb_build_object(
                      'thumbnail_url', 'mxc://' || mf.server_name || '/' || mf.media_id))
         )
   LIMIT 1000
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.metadata(route_template: "cron:media_orphan_detection")
    start_ms = System.monotonic_time(:millisecond)

    threshold_ms = System.system_time(:millisecond) - orphaned_hours() * 60 * 60 * 1000

    %{rows: rows} = repo().query!(@sql_select_orphan_candidates, [threshold_ms])

    candidate_media_ids = Enum.map(rows, fn [media_id, _server_name, _uploaded_at] -> media_id end)
    candidate_count = length(candidate_media_ids)

    audit_writer().log(
      @audit_actor,
      "media_orphan_detection_run",
      "media_orphan_detection",
      nil,
      %{
        "candidate_count" => candidate_count,
        "candidate_media_ids" => candidate_media_ids
      },
      "success"
    )

    duration_ms = System.monotonic_time(:millisecond) - start_ms

    Logger.info(%{
      candidate_count: candidate_count,
      duration_ms: duration_ms
    })

    :ok
  end

  defp orphaned_hours do
    Application.get_env(:nebu, :media_orphan_detection, [])
    |> Keyword.get(:orphaned_hours, 48)
  end

  defp repo,
    do: Application.get_env(:nebu_http, :media_orphan_detection_repo_module, Nebu.Repo)

  defp audit_writer,
    do: Application.get_env(:nebu_http, :media_audit_writer_module, Nebu.Compliance.AuditWriter)
end
