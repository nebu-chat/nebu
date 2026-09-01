# Dependency research — 2e-reserved-upload-cleanup-cron

## Finding 1: Oban is absent from the codebase
Confirmed: `grep -i oban server/mix.exs server/mix.lock server/config/config.exs` — no hits.
`server/lib/nebu/workers/` does not exist. Sprint-status shows 4a/4b/4c all still
`ready-for-dev` (not done) — 2e is running before them in actual build order, exactly the
scenario the story's own Dependencies section anticipated.

Story 4b's own (unimplemented) story file already fully specifies the Oban-bootstrap plan
(its AC1/AC2/Technical Requirements), since 4b was written assuming it would be first to
need Oban. Because 2e now lands first, 2e absorbs that bootstrap work:
- `server/mix.exs`: add `{:oban, "~> 2.18"}`.
- New raw-SQL migration (`server/priv/migrations/000026_oban_jobs.{up,down}.sql` — 000025 is
  current HEAD) containing Oban's officially published Postgres schema (oban_jobs table +
  oban_job_state enum + indexes + notify trigger/function) hand-translated into the project's
  raw-SQL convention (NOT `Oban.Migration.up/1` — Nebu's migration runner is not
  Ecto-Migration-based, per 1a's and 4b's own note), with an explicit
  `GRANT SELECT, INSERT, UPDATE, DELETE ON oban_jobs TO nebu_app;` (mirrors the
  `Nebu.Matrix.MigrationsGrantTest` convention — extend that test file with a new
  `000026_oban_jobs.up.sql` describe block).
- `server/lib/nebu/application.ex`: add `{Oban, Application.fetch_env!(:nebu, Oban)}` after
  `Nebu.Repo` starts (same DB-gated pattern as the other `repo_children/0` entries).
- `server/config/config.exs`: `config :nebu, Oban, repo: Nebu.Repo, plugins: [{Lifeline,
  rescue_after: :timer.minutes(60)}, {Pruner, max_age: ...}, {Oban.Plugins.Cron, crontab:
  [{"*/15 * * * *", Nebu.Workers.MediaReservedUploadCleanupWorker}]}], queues:
  [media_cleanup: [limit: 10, shutdown_grace_period: :timer.seconds(30)]]` — 2e is the FIRST
  to populate the `crontab:` key (4b's own text: "The crontab: key is left for later stories
  (2e, 8a/8c, 10a) to append entries to"). Do NOT add a `media_scan` queue entry — that is
  4b's own scope, out of bounds for this story.
- `server/test/nebu/release_test.exs`: extend the hardcoded `list_up_migrations/1` version
  list from `1..25` to include `26`, with an explanatory comment mirroring the existing style
  (see entries for 000022-000025).

## Finding 2: `unused_expires_at` is not a persisted column
The story's own AC1/AC3 and Technical Requirements SQL (`WHERE state = 'reserved' AND
unused_expires_at < $1`) assume a persisted `media_files.unused_expires_at` column. It does
not exist (`server/priv/migrations/000001_init.up.sql` — only `uploaded_at BIGINT` exists;
confirmed via `grep unused_expires_at server/priv/migrations/*.sql` — zero hits).

Story 2b's Dev Agent Record (`docs/stories/media-security-admin-control/
2b-put-media-upload.md`) resolved this identical assumption for the PUT handler: derive
expiry LIVE as `row.uploaded_at + unused_expires_ms() < System.system_time(:millisecond)`,
using the same private config resolver `Nebu.Media.create/1` uses
(`Application.get_env(:nebu_http, :media_unused_expires_ms, 86_400_000)`). 2b's own note is
explicit: "Story 2e's cleanup cron must use this identical formula, not a `WHERE
unused_expires_at < NOW()` column read — there is no such column."

Resolution for 2e: the worker's SELECT must be
`SELECT id, uploaded_at FROM media_files WHERE state = 'reserved' LIMIT 1000` and the
expiry comparison (`uploaded_at + unused_expires_ms() < now_ms`) happens in Elixir, exactly
mirroring `Nebu.Media`'s private `reservation_expired?/1` (media.ex:364-369). The worker
should read the same app-env key (`:nebu_http, :media_unused_expires_ms`, default
86_400_000) — do not introduce a second/different config key or duplicate default.

## Finding 3: story's literal StateMachine.transition/4 call syntax is wrong
Story AC3/Technical Requirements write `Nebu.Media.StateMachine.transition(media_id,
:hard_deleted, actor_type: :system, actor_id: nil)` (keyword-style). The real signature
(`server/lib/nebu/media/state_machine.ex:119-134`) is
`transition(media_id, to_state, actor, metadata \\ %{})` where `actor` is a 2-tuple —
`{:system, nil}` or `{:admin, uuid}` — not keyword args. 4b's own (unimplemented) worker
example already calls it correctly: `state_machine().transition(media_id, :scanning,
{:system, nil})`. 2e's worker/tests must use the real tuple form:
`Nebu.Media.StateMachine.transition(media_id, :hard_deleted, {:system, nil})`.

## Finding 4: `:reserved -> :hard_deleted` guard-table edge does not exist yet
Confirmed in `server/lib/nebu/media/state_machine.ex` `@transitions` map: `reserved:
[:quarantined]` only. This story is the first caller and must add `:hard_deleted` to that
list, exactly as the story's own AC4/File List already anticipates (not a story-text error —
proceed as written).

## Oracle gate result (no blocking spec objection)
See oracle-context.md — zero wire-protocol MUST governs this worker (pure internal
housekeeping); reinforced that 2b's PUT-handler expiry check must stay independent of this
cron's 15-min cadence (already true — 2b's check is fully live/derived, no dependency on this
worker having run).
