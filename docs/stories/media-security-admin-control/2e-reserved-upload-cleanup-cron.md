---
story_id: 2e-reserved-upload-cleanup-cron
title: "Async Upload Endpoints: Cleanup Cron for Reserved Uploads"
epic: media-security-admin-control
status: done
security_review: optional
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

`POST /_matrix/media/v1/create` (Story 2a) creates a `media_files` row in state `:reserved`
and hands the client a `content_uri` + `unused_expires_at` (default 24h, per spec
recommendation). If the client never follows up with `PUT /_matrix/media/v3/upload/...`
(Story 2b), that row sits in `:reserved` forever unless something cleans it up. The live
expiry check in the PUT handler (2b) only rejects a *late* upload attempt — it never
reclaims the abandoned reservation itself. Left alone, these rows accumulate and count
against the per-user pending-upload limit (`max_pending_per_user`, Story 2a), eventually
starving legitimate uploaders with `429 M_LIMIT_EXCEEDED`.

This story adds an Oban-cron housekeeping job (`Nebu.Workers.MediaReservedUploadCleanupWorker`)
that periodically finds `:reserved` rows whose `unused_expires_at` has passed and retires
them. Since no bytes were ever written for a `:reserved` row (`storage_key` is `NULL` from
creation), there is nothing to delete from S3 — the job only needs to move the row to its
terminal state. Per the epic-wide DB-Record-Invariante ("the `media_files` record is never
physically deleted") and the Story 1b invariant ("no raw SQL `UPDATE` on `state` outside
`Nebu.Media.StateMachine`"), this is a `Nebu.Media.StateMachine.transition/3` call to
`:hard_deleted`, not a `DELETE FROM media_files` statement and not a raw `UPDATE`.

This is best-effort housekeeping, not the authoritative expiry enforcement — that already
lives in the PUT handler (2b), which checks `unused_expires_at` live on every request. This
cron only exists so abandoned reservations don't accumulate between PUT attempts.

## User Story

As the Nebu server operator, I want abandoned `:reserved` upload reservations to be
automatically retired after their `unused_expires_at` deadline, so that stale reservations
don't accumulate in `media_files` and don't count against a user's pending-upload limit
indefinitely.

## Acceptance Criteria

1. **TTL source — no new config value.** The expiry used by the cleanup job is the
   `unused_expires_at` timestamp already persisted per-row by Story 2a (server-side default
   24h, per the spec recommendation baked into the `POST /create` handler's static
   `config.exs` value). This TTL is **not** one of the `media_config` (Story 9a) keys exposed
   in the `/admin/media/settings` UI (Story 9b) — that list covers
   `max_upload_size_bytes`/`max_file_size_bytes`/`max_pending_per_user`/`max_stall_ms`/
   `deleted_days`/`infected_days`/`orphaned_hours`/`webhook_url` only. The cleanup job does
   not introduce a separate, duplicate TTL — it simply compares `NOW()` against each row's
   own `unused_expires_at`.
2. **Cron schedule.** `Nebu.Workers.MediaReservedUploadCleanupWorker` runs on an
   `Oban.Plugins.Cron` schedule (every 15 minutes — `"*/15 * * * *"`), configured in
   `config/config.exs` alongside the other Oban cron entries introduced by this epic
   (ADR-025). A 15-minute cadence is intentionally tighter than the daily 02:00 UTC
   `MediaCleanupWorker` cron (Story 8a) because stale `:reserved` rows directly consume a
   user's `max_pending_per_user` budget — leaving them for up to a day would let one
   forgetful client lock a user out of new reservations.
3. **State transition via `Nebu.Media.StateMachine`, not a raw DELETE/UPDATE.** For every
   `media_files` row where `state = 'reserved' AND unused_expires_at < NOW()`, the worker
   calls `Nebu.Media.StateMachine.transition(media_id, :hard_deleted, actor_type: :system,
   actor_id: nil)`. No bytes exist for these rows (`storage_key` is `NULL` since creation),
   so there is nothing to delete from S3/MinIO and no `Nebu.Media.Storage` call is needed —
   only the state transition (which itself sets `hard_deleted_at = NOW()` and
   `uploader_id = NULL`, consistent with the epic's DB-Record-Invariante). The row itself is
   never physically deleted (`media_files` row count is unaffected; only its `state` and the
   nulled columns change).
4. **New guard-table edge.** `:reserved → :hard_deleted` is a new entry in
   `Nebu.Media.StateMachine`'s allowed-transitions table (Story 1b), distinct from the
   regular `:reserved → :quarantined` edge used by the PUT handler (2b). If Story 1b's guard
   table does not already define this edge, it must be added here — this story is its first
   and (at this point in the build order) only caller.
5. **Idempotent under repeated/concurrent runs.** Running the job twice in a row (or two
   overlapping executions) must not error and must not double-process a row. After the first
   run transitions a row to `:hard_deleted`, the job's own `WHERE state = 'reserved'` filter
   excludes it from the next run's result set. If two executions race on the same row before
   either commits, the second transition attempt is rejected by the StateMachine's guard
   (current state is no longer `:reserved`) and is treated as a no-op, not a crash or retried
   failure.
6. **Non-expired `:reserved` rows are untouched.** A `:reserved` row whose
   `unused_expires_at` is still in the future is never selected by the job and is not
   transitioned, regardless of how long ago it was created relative to the job's own run
   cadence.

## Acceptance Tests

Using `Oban.Testing` (`use Oban.Testing, repo: Nebu.Repo`), unit-testing the worker's
`perform/1` callback directly (matching this codebase's existing worker-test style of
injectable `FakeRepo`/fake-collaborator doubles rather than a full DB sandbox — see
`test/nebu/compliance/session_expiry_worker_test.exs`):

1. **`test "expired :reserved rows are transitioned to :hard_deleted via the state machine"`**
   — `FakeRepo` returns one or more `media_files` rows with `state: "reserved"` and
   `unused_expires_at` in the past; `perform_job(MediaReservedUploadCleanupWorker, %{})`
   returns `:ok`; assert the injected `FakeStateMachine.transition/3` double was called once
   per row with `(media_id, :hard_deleted, actor_type: :system, actor_id: nil)`.
2. **`test "non-expired :reserved rows are left untouched"`** — `FakeRepo`'s query returns no
   rows (simulating the `unused_expires_at < NOW()` filter excluding a fresh reservation);
   assert `FakeStateMachine.transition/3` is never called.
3. **`test "the job is idempotent under repeated runs"`** — first `perform_job/2` call
   transitions a row and the fake is updated to reflect its new state (no longer returned by
   the `:reserved` query); a second `perform_job/2` call on the same worker returns `:ok` and
   results in zero additional `FakeStateMachine.transition/3` calls.
4. **`test "the job is idempotent when two executions race on the same row"`** — simulate a
   concurrent second attempt against a row that has *already* transitioned (the fake
   StateMachine returns `{:error, :invalid_transition}` for a `:reserved → :hard_deleted` call
   on a row no longer in `:reserved`); assert the worker treats this as a no-op / returns
   `:ok` rather than raising or returning `{:error, _}` that would trigger an Oban retry.
5. **`test "cleanup never issues a raw UPDATE/DELETE on media_files.state"`** — assert (via
   the `FakeRepo` call log, matching the assertion style already used for the grep-invariant
   check in Story 1b) that the only SQL the worker itself executes is the `SELECT` of
   candidate rows; every state change is attributed to
   `Nebu.Media.StateMachine.transition/3`, never to a `Repo.query!("UPDATE media_files ...")`
   or `"DELETE FROM media_files ..."` issued directly by the worker.

## Technical Requirements

- **Oban worker module:** `Nebu.Workers.MediaReservedUploadCleanupWorker`, in
  `server/lib/nebu/workers/media_reserved_upload_cleanup_worker.ex`. `use Oban.Worker,
  queue: :media_cleanup, max_attempts: 5` — same queue/backoff conventions established by
  ADR-025 for the epic's other housekeeping crons (shared `:media_cleanup` queue, distinct
  from the `:media_scan` queue used by `MediaScanWorker`).
- **Cron schedule config:** `Oban.Plugins.Cron` entry in `config/config.exs`, added to the
  existing `crontab:` list alongside whatever entries Story 4b/8a already registered:
  ```elixir
  {"*/15 * * * *", Nebu.Workers.MediaReservedUploadCleanupWorker}
  ```
- **TTL config source:** none new. The query is:
  ```sql
  SELECT id FROM media_files
   WHERE state = 'reserved'
     AND unused_expires_at < $1  -- NOW(), ms-epoch to match unused_expires_at's unit
   LIMIT 1000
  ```
  (`LIMIT` bound matches the existing pattern in `Nebu.Compliance.SessionExpiryWorker`'s
  scan query, so a single tick can't unboundedly scan the table.)
- **Exact state-machine call:**
  `Nebu.Media.StateMachine.transition(media_id, :hard_deleted, actor_type: :system, actor_id:
  nil)` for every row returned by the query above. `actor_id: nil` matches the existing
  convention for system-initiated transitions (Story 1b: "der `actor_id` ist für
  Scanner-Transitions NULL, `actor_type = :system`" — the same rule applies to this
  cron-driven transition).
- **Runtime dependency note:** per the epic's recommended build order, Story 4b
  (`MediaScanWorker`) is built before this story and already adds the Oban dependency,
  Postgres-backed job tables, and the app's Oban supervisor entry — this story only adds a
  new worker module and a new cron-table entry, it does not re-introduce Oban itself.

## File List

- `server/lib/nebu/workers/media_reserved_upload_cleanup_worker.ex` — NEW. The Oban worker.
- `server/lib/nebu/media/state_machine.ex` — UPDATE (only if needed). Add the
  `:reserved → :hard_deleted` edge to the allowed-transitions guard table if it is not
  already present from Story 1b.
- `server/config/config.exs` — UPDATE. Add the cron entry to the existing
  `Oban.Plugins.Cron` `crontab:` list.
- `server/test/nebu/workers/media_reserved_upload_cleanup_worker_test.exs` — NEW. Acceptance
  tests above.

## Dev Agent Guardrails

### Do Not Change

- **Never issue a raw SQL `UPDATE` or `DELETE` against `media_files.state`.** All state
  changes go through `Nebu.Media.StateMachine.transition/3`. This is the same invariant Story
  1b's grep-test enforces project-wide ("kein direktes SQL-UPDATE auf `state` außerhalb von
  `Nebu.Media.StateMachine`") and that the epic-level Definition of Done re-checks in CI —
  this worker must not be the story that quietly reintroduces a raw `UPDATE`/`DELETE` because
  "there are no bytes to worry about." The DB-side append-only trigger on
  `media_state_transitions` (ADR-031) also means a hand-rolled transition-log insert bypassing
  `StateMachine` would fail outright.
- Do not physically `DELETE FROM media_files` for cleaned-up rows. The row must remain (per
  the epic's DB-Record-Invariante) with `state = 'hard_deleted'`, `uploader_id = NULL`,
  `hard_deleted_at` set — `storage_key` is already `NULL` and needs no change.
- Do not touch the PUT handler's live expiry check (Story 2b) — that is the authoritative
  enforcement path; this cron is best-effort housekeeping only, and the two must not be
  merged into one code path.

## Dependencies

- **1a** — `media_files` migration (the table and columns this job queries/transitions).
- **1b** — `Nebu.Media.StateMachine` module and its allowed-transitions guard table (this
  story adds the `:reserved → :hard_deleted` edge to it).
- **2a** — `POST /_matrix/media/v1/create`, which produces the `:reserved` rows (and their
  `unused_expires_at` values) that this job cleans up.
- Implicit runtime dependency on Oban being configured (introduced by Story 4b in the
  recommended build order, which precedes this story) — not a new dependency this story
  introduces, but a precondition for the cron to run at all.

## Dev Agent Record

### Scope adaptations (pre-dev dependency-research, 2026-07-14)

Actual build order landed 2e BEFORE 4a/4b/4c (confirmed: Oban absent from `mix.exs`/
`mix.lock`/`config.exs`, `server/lib/nebu/workers/` did not exist, sprint-status still showed
4a/4b/4c as `ready-for-dev`). Per the story's own Dependencies note anticipating this, 2e
absorbed Story 4b's originally-planned AC1/AC2 Oban bootstrap work (4b's own unimplemented
story text already fully specified this plan and was used as the reference):
- `mix.exs`: `{:oban, "~> 2.18"}` (resolved 2.23.0).
- `server/priv/migrations/000026_oban_jobs.up/down.sql`: Oban's Postgres schema
  (`oban_job_state` enum, `oban_jobs`, `oban_peers` — the default table-based leader-election
  module `Oban.Plugins.Cron` needs) hand-translated from the fetched dependency's own
  migration source into this project's raw-SQL convention (this project's migration runner,
  `Nebu.Release`, is not Ecto-Migration-based). Deliberately omits the `pg_notify`
  trigger/function the official schema creates in V01/V08 and itself drops in V12 — confirmed
  absent as of schema version 14.
- `server/lib/nebu/application.ex`: `{Oban, Application.fetch_env!(:nebu, Oban)}` added to
  `repo_children/0` (DB-gated, after `Nebu.Repo`).
- `server/config/config.exs`: base Oban config (`repo`, `shutdown_grace_period`,
  `Lifeline`/`Pruner` plugins, `media_cleanup` queue). The `Oban.Plugins.Cron` crontab entry
  itself was deferred during ATDD (`Oban.Plugins.Cron` validates every crontab worker module
  eagerly via `Code.ensure_loaded?/1` at `Oban.start_link/1` time — listing the worker before
  it existed would have crashed the app on boot) and added once the worker module existed in
  dev-story.

Two factual corrections to this story's own original AC/Technical-Requirements text, found
during dependency-research and confirmed against the actual codebase before ATDD:
1. **`unused_expires_at` is NOT a persisted column.** `media_files` has `uploaded_at BIGINT`
   only. Story 2b's Dev Agent Record already hit this exact assumption for the PUT handler and
   resolved it: derive expiry LIVE as `uploaded_at + unused_expires_ms() < now_ms`, reading the
   same `Application.get_env(:nebu_http, :media_unused_expires_ms, 86_400_000)` key
   `Nebu.Media.create/1` already uses. This story's worker uses the identical formula (SQL:
   `WHERE state = 'reserved' AND uploaded_at < $1 LIMIT 1000`, with `$1` computed in Elixir as
   `now_ms - unused_expires_ms()`) — not a `WHERE unused_expires_at < NOW()` column read.
2. **`StateMachine.transition/4`'s real call shape is a 2-tuple actor, not keyword args.** The
   story's original text showed `transition(media_id, :hard_deleted, actor_type: :system,
   actor_id: nil)`; the real signature (`state_machine.ex`) is `transition(media_id, to_state,
   actor, metadata \\ %{})` where `actor :: {:system, nil} | {:admin, uuid}`. The worker calls
   `StateMachine.transition(media_id, :hard_deleted, {:system, nil})`.

### Pre-dev test-review (2 MAJOR fixed before dev-story started)

- AC4 (new `reserved -> hard_deleted` guard-table edge) had zero coverage in the worker's own
  test file (it only exercises a hand-rolled `FakeStateMachine`) and would have regressed
  `state_machine_test.exs`'s existing table-driven guard test once the real edge was added.
  Fixed: extended that file's `@full_guard_table` with the new edge ahead of dev-story, so the
  table-driven test went RED (edge not yet real) then GREEN once dev-story added it.
- AC5's race-idempotency test could not distinguish narrow `{:error, {:invalid_transition, _,
  _}}` handling from a catch-all `rescue`/broad-`case` swallowing any error as `:ok`. Fixed:
  added a 7th test forcing an unexpected error shape and asserting the worker propagates it
  (`{:error, _}`) rather than reporting `:ok`.
- A genuine, unrelated flakiness bug was also found and fixed during this pass: the worker
  test file's named `Agent`s were never explicitly stopped in `on_exit`, creating a rare
  `{:error, {:already_started, pid}}` teardown race between tests. Fixed via synchronous
  `Agent.stop/1` calls in `on_exit`.

### Implementation (dev-story)

- `Nebu.Workers.MediaReservedUploadCleanupWorker` (new): `use Oban.Worker, queue:
  :media_cleanup, max_attempts: 5`. `perform/1` selects candidate rows with the TTL predicate
  in SQL (not filtered in Elixir after an unbounded-by-expiry `LIMIT 1000` scan — see
  code-review MAJOR below), then `Enum.reduce_while/3`s over them calling
  `StateMachine.transition/4` per row: `{:ok, :hard_deleted}` continues, `{:error,
  {:invalid_transition, _, _}}` (lost race) continues as a no-op, any other error halts and
  returns `{:error, reason}` so Oban retries the whole job.
- `state_machine.ex`: added `:hard_deleted` to `reserved`'s guard-table entry. Also added a
  new, `:hard_deleted`-specific UPDATE statement in `write_transition/6` that additionally
  nulls `uploader_user_id` and stamps `hard_deleted_at = now()` — this is the FIRST code path
  in the codebase to ever reach `:hard_deleted` (the pre-existing `deleted -> hard_deleted`
  edge had no caller before this story either), so this behavior did not previously exist
  anywhere.
- `config.exs`: crontab entry populated (`{"*/15 * * * *",
  Nebu.Workers.MediaReservedUploadCleanupWorker}`).

### Code-review (1 cycle, 1 CRITICAL + 1 MAJOR + 2 MINOR fixed)

- **CRITICAL**: the new hard_deleted-nulling UPDATE set `uploader_user_id = NULL`, but that
  column was `TEXT NOT NULL` since `000001_init.up.sql` with nothing ever dropping the
  constraint — every real invocation would raise a Postgres `not_null_violation`, completely
  undetected by the test suite because the worker's own tests swap in `FakeStateMachine`.
  Fixed: new migration `000027_media_files_uploader_user_id_nullable.up/down.sql` (`ALTER
  TABLE media_files ALTER COLUMN uploader_user_id DROP NOT NULL`) plus a new real-`Nebu.Repo`
  round-trip test in `state_machine_test.exs` that exercises the actual `write_transition/6`
  SQL and asserts `uploader_user_id IS NULL`, `hard_deleted_at` set, and the row still exists.
- **MAJOR**: the expiry predicate was originally filtered in Elixir AFTER an unfiltered
  `LIMIT 1000` SQL scan of all `:reserved` rows — under high `:reserved` row counts, expired
  rows could be starved behind fresh ones. Fixed: moved the predicate into the SQL `WHERE`
  clause (mirrors `Nebu.Compliance.SessionExpiryWorker`'s own pattern).
- 2 MINOR: `Oban.Plugins.Pruner`'s `max_age` expression readability (`:timer.hours(24) |>
  div(1000)` → plain `60 * 60 * 24`); down-migration `IF EXISTS` guards added for symmetry
  with the up-migration's `IF NOT EXISTS` on the enum.
- Re-verified independently via a full `make redeploy` (migration 000027 applied cleanly, no
  crash) + `make test-integration` (2286 tests, 32 failures — all in the epic's established
  pre-existing/unrelated categories, 0 media/worker/state_machine failures) + `make
  test-unit-elixir` (1825 passed, exit 0 clean).

### Security review (Kassandra, 2026-07-14)

APPROVED — 0 CRITICAL/HIGH. Independently re-verified both code-review fixes. 2 LOW: F-1
(nulling `uploader_user_id` on hard-delete flips the true reservation owner's later PUT-upload
response from 404 to 403 — a weak existence oracle, gated by 128-bit unguessable `media_id`s;
fix deferred to a future story since it touches pipeline-protected `media.ex`) and F-2 (the
shared hard_deleted UPDATE path will need to capture uploader identity into transition
metadata before nulling, once the pre-existing `deleted -> hard_deleted` edge gets a real
caller for actual uploaded content — forward watch-flag, not actionable now). Full report:
`docs/stories/media-security-admin-control/security-reports/
2e-reserved-upload-cleanup-cron-security-review-2026-07-14.md`.

**Test results:** `server/test/nebu/workers/media_reserved_upload_cleanup_worker_test.exs`
7/7 passed; `state_machine_test.exs`/`migrations_grant_test.exs`/`release_test.exs` all green;
full suite 1825 passed/4 skipped/457 excluded (unit), 2286 tests/32 failures/5 skipped
(integration, 0 media-related).
